# Load data from input files

"""
    load(params::dict)::dict

Load Kimai, vacation, and sickdays data from the files defined in `params` and
return as ordered dict with entries `"kimai"`, `"vacation"`, and `"sickdays"`.
"""
function load(params::dict)::dict
  # Initialise dict
  data = dict()
  # Load Kimai times
  data["kimai"] = load_kimai(params)
  # Set current Kimai period for restriction
  data["stats"] = dict{String,Any}(
    "start" => data["kimai"].in[end],
    "stop" => data["kimai"].out[1]
  )
  # Load off-days
  load_offdays!(data, params, "vacation")
  load_offdays!(data, params, "sickdays")
  # Return Kimai data
  return data
end


"""
    load_kimai(params::dict)::DataFrame

Load input data from files defined by `params["Datasets"]` and return as `DataFrame`.
"""
function load_kimai(params::dict)::DataFrame
  # Read Kimai history
  kimai = CSV.read(params["Datasets"]["kimai"], DataFrame, select=collect(1:5), stringtype=String)
  df.rename!(kimai, ["date", "in", "out", "time", "hours"])
  # Convert working hours and rename column
  kimai.time = Dates.canonicalize.(kimai.time-Time(0))

  # Set year
  current_year = params["Settings"]["finalyear"]
  start, stop = DateTime[], DateTime[]
  # Loop over dates
  for i = 1:length(kimai.date)
    # Construct DateTime for in/out times
    date = Date(kimai.date[i]*string(current_year), dateformat"d.m.y")
    if i > 1 && date > start[end]
      current_year -= 1
      date = Date(kimai.date[i]*string(current_year), dateformat"d.m.y")
    end
    push!(start, DateTime(date, kimai.in[i]))
    push!(stop, DateTime(date, kimai.out[i]))
  end
  # Convert kimai times
  kimai.in = start
  kimai.out = stop
  # Delete obsolete date column
  df.select!(kimai, df.Not("date"))
  # Reduce data to current session
  i = findfirst(kimai.out .≤ params["Recover"]["log ended"])
  isnothing(i) || deleteat!(kimai, i:size(kimai, 1))
  # Return kimai dataframe
  return kimai
end


"""
    function load_offdays!(
      data::dict,
      params::dict,
      type::String
    )::DataFrame

Load the `type` of offdays from the `"Datasets"` in `params` to a `DataFrame`,
add an entry `type` to `data`, and return the `DataFrame`.
"""
function load_offdays!(
  data::dict,
  params::dict,
  type::String
)::DataFrame
  # Return empty DataFrame with default columns for non-existing files
  off = params["Datasets"][type]
  if off isa Int
    off == 0 && @info "$type not specified, use Int or data file to set $type"
    data[type] =  DataFrame(reason=String[type], start=Date[data["stats"]["start"]],
      stop=Date[data["stats"]["stop"]], count=Int[off])
    return data[type]
  elseif isempty(off)
    data[type] = DataFrame(reason=String[], start=Date[], stop=Date[], count=Int[])
    return data[type]
  end
  # Read input file
  offdays = CSV.read(off, DataFrame, stringtype=String, stripwhitespace=true)
  # Process dates and convert to date format
  start, stop, count, reason = Date[], Date[], Int[], String[]
  for i = 1:size(offdays, 1)
    # Split ranges into start and stop date
    current_date = strip.(split(offdays[i, 1], "-"))
    # Process dates, use same stop date as start date for single date
    startdate = Date(current_date[1], dateformat"d.m.y")
    stopdate = length(current_date) == 1 ? startdate : Date(current_date[2], dateformat"d.m.y")
    # Ignore past dates
    startdate > data["stats"]["start"] || continue
    # Save dates of complete of period, reason, and the number of offdays
    # Offday count at the edges is restricted to within start and stop date
    push!(start, startdate)
    push!(stop, stopdate)
    push!(reason, offdays[i, 2])
    push!(count, countbdays(params["tmp"]["calendar"], startdate, stopdate))
    if startdate ≤ data["stats"]["stop"] && stopdate > data["stats"]["stop"]
      # Correct stop date for later balance calculation,
      # if offday period partly overlaps with end of Kimai period
      data["stats"]["stop"] = DateTime(stopdate, Time(23,59,59))
    end
  end
  # Add offdays to dataset
  colname = names(offdays)[2]
  offdays = DataFrame(colname = reason; start, stop, count)
  df.rename!(offdays, [colname, "start", "stop", "days"])
  # Save data and add balance counter for vacation
  data[type] = offdays
  type == "vacation" && add_vacationcounter!(data, params)
  return offdays
end


"""
    add_vacationcounter!(data::dict, params::dict)::Nothing

Add a column `remaining` to the `vacation` DataFrame in `data` with the aid of
`params`.
"""
function add_vacationcounter!(data::dict, params::dict)::Nothing

  # Setup balance and deadline parameters
  params["tmp"]["balance"] = params["Settings"]["vacation days"] - params["Recover"]["vacation"]
  params["tmp"]["year"] = Date(year(data["stats"]["start"]), 12, 31)
  params["tmp"]["deadline"] = params["Settings"]["vacation deadline"] + Year(data["stats"]["start"])
  params["tmp"]["factor"] = max(1, year(params["Settings"]["vacation deadline"]))
  if data["stats"]["start"] > params["tmp"]["deadline"]
    data["tmp"]["deadline"] = Date(year(data["stats"]["start"]),12,31)
  end

  # Check and adjust balance
  account = Int[]
  for row in eachrow(data["vacation"])
    adjust_balance!(account, row, params)
  end
  # Add balance to vacation data
  data["vacation"][!, "remaining"] = account
  return
end


"""
    function adjust_balance!(
      account::Vector{Int},
      vacation::df.DataFrameRow,
      params::dict
    )::Nothing

Add the balance with remaining vacation days to the `account` based on the previous
balance and other parameters in `params` for the current `vacation`.
"""
function adjust_balance!(
  account::Vector{Int},
  vacation::df.DataFrameRow,
  params::dict
)::Nothing
  # Add new vacation at the beginning of the new year
  if vacation.stop > params["tmp"]["year"]
    # Check correct balance at the end of the year,
    # if vacation starts in old year and ends in new year
    if vacation.start < params["tmp"]["year"] &&
      params["tmp"]["balance"] - countbdays(params["tmp"]["calendar"], vacation.start, params["tmp"]["year"]) < 0
      @warn "too much vacation taken before end of year; check whether you are allowed to use next year's vacation"
    end
    n = year(vacation.stop) - year(params["tmp"]["year"])
    params["tmp"]["year"] += Year(n)
    params["tmp"]["balance"] += n*params["Settings"]["vacation days"]
  end
  # Cap vacation at vacation deadline
  if vacation.stop > params["tmp"]["deadline"]
    # Calculate unused vacation days and days in current vacation taken before the cap
    overhead = params["tmp"]["balance"] - params["tmp"]["factor"]*params["Settings"]["vacation days"]
    overlap = countbdays(params["tmp"]["calendar"],
      vacation.start, params["tmp"]["deadline"])
    # Cap the vacation days to maximum allowed number and print warning
    params["tmp"]["balance"] = min(params["tmp"]["factor"]*params["Settings"]["vacation days"], params["tmp"]["balance"])
    if vacation.start < params["tmp"]["deadline"]
      # Correct for vacation days taken before the cap
      params["tmp"]["balance"] += max(min(overlap, overhead), 0)
      overhead -= overlap
    end
    if overhead > 0
      @warn "$overhead vacation days lost at $(params["tmp"]["deadline"])"
    end
    # Update deadline to next year
    params["tmp"]["deadline"] += Year(1)
  end
  # Update balance for all vacation periods and save balance
  params["tmp"]["balance"] -= vacation.days
  push!(account, params["tmp"]["balance"])
  # Warn, if too much vacation is used
  params["tmp"]["balance"] > 0 || @warn string("not enough vacation left; reduce vacation from ",
    vacation.start, " – ", vacation.stop, " and subsequent vacations this year")
  return
end
