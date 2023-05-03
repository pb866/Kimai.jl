## Load data from input files

"""
    load!(params::dict)::dict

Load Kimai, vacation, and sickdays data from the files defined in `params` and
return as ordered dict with entries `"kimai"`, `"vacation"`, and `"sickdays"`.
"""
function load!(params::dict)::dict
  # Initialise dict
  data = dict()
  # Load Kimai times
  data["kimai"] = load_kimai(params)
  # Set current Kimai period for restriction
  data["stats"] = dict{String,Any}(
    "start" => data["kimai"].in[end],
    "stop" => data["kimai"].out[1]
  )
  @debug "init stop date" data["stats"]["stop"]
  # Load off-days
  load_offdays!(data, params, "vacation")
  @debug "refined stop date" data["stats"]["stop"]
  load_offdays!(data, params, "sickdays")
  # Check vacation, issue warnings for low credit/unused vacation
  check_vacationcredit(data, params)
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
  current_year = params["Settings"]["final year"]
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
  # Get current off-day type
  off = params["Datasets"][type]
  @debug "off-day source" type off
  if off isa Int
    # Return DataFrame with given value for current Kimai range, check enough vacation is available
    off == 0 && @info "$type not specified, use Int or data file to set $type"
    data[type] =  DataFrame(
      reason=String[type],
      start=Date[data["stats"]["start"]],
      stop=Date[data["stats"]["stop"]],
      days=Int[off],
    )
    if type == "vacation"
      credit = params["Recover"]["vacation"] - off
      credit < 0 && @warn("not enough vacation left; reduce vacation by $(abs(credit)) days",
         _module=nothing, _group=nothing, _file=nothing, _line=nothing)
      data[type].remaining = Int[credit]
      save_tmp!(data, params)
    end
    # Save tmp data and return the new data section
    return data[type]
  elseif isempty(off)
    # Return empty DataFrame with default columns for non-existing files
    data[type] =  DataFrame(
      reason=String[type],
      start=Date[data["stats"]["start"]],
      stop=Date[data["stats"]["stop"]],
      days=Int[0]
    )
    if type == "vacation"
      data[type].remaining = Int[params["Settings"]["vacation days"]]
      save_tmp!(data, params)
    end
    # Save tmp data and return the new data section
    return data[type]
  end
  # Read input file
  offdays = CSV.read(off, DataFrame, stringtype=String, stripwhitespace=true)
  # Setup balance and deadline parameters for vacation
  type == "vacation" && save_tmp!(data, params)
  # Process dates and convert to date format
  start, stop, days, reason, remaining = Date[], Date[], Int[], String[], Int[]
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
    offdaycounter!(days, remaining, startdate, stopdate, type, data, params)
    if startdate ≤ data["stats"]["stop"] && stopdate > data["stats"]["stop"]
      # Correct stop date for later balance calculation,
      # if off-day period partly overlaps with end of Kimai period
      data["stats"]["stop"] = DateTime(stopdate, Time(23,59,59))
    end
  end
  # Add offdays to dataset
  @debug "offdays" length(reason) length(start) length(stop) length(days) length(remaining) type
  colname = names(offdays)[2]
  offdays = DataFrame(colname = reason; start, stop, days)
  df.rename!(offdays, [colname, "start", "stop", "days"])
  # Ensure, DataFrame i  @debug type data["stats"]["start"] data["stats"]["stop"] offdays
  nodata = isempty(offdays)
  nodata && push!(offdays, (type, data["stats"]["start"], data["stats"]["stop"], 0))
  # Add remaining vacation days
  if type == "vacation"
    @debug "vacation" [params["Settings"]["vacation days"]] offdays
    offdays.remaining = nodata ? [params["Settings"]["vacation days"]] : remaining
  end
  # Save data and add balance counter for vacation
  data[type] = offdays
  return offdays
end


"""
    function vacationaccout!(
      remaining::Vector{Int},
      start::Date,
      stop::Date,
      params::dict
    )::Nothing
Add the balance with `remaining` vacation days based on the previous
balance and other parameters in `params` for the current vacation (defined by the
`start` and `stop` day).
"""
function offdaycounter!(
  days::Vector{Int},
  remaining::Vector{Int},
  start::Date,
  stop::Date,
  type::String,
  data::dict,
  params::dict
)::Nothing
  #* Add offdays and return for non-vacation types
  offdays = countbdays(params["tmp"]["calendar"], start, stop)
  if type != "vacation"
    push!(days, offdays)
    return
  end
  #* Apply X-mas rule
  Xmas, NYE = Date(params["tmp"]["year"], 12, 24), Date(params["tmp"]["year"], 12, 31)
  vacation = start:Day(1):stop
  if params["Settings"]["Xmas rule"] && Xmas in vacation && cal.isbday(params["tmp"]["calendar"], Xmas)
    # Flag Xmas in vacation, if it is a business day and the X-mas rule is active
    params["tmp"]["Xmas"] = true
    # Adjust work load balance for Christmas
    params["tmp"]["Xfactor"] -= 1
  end
  if params["tmp"]["Xmas"] && NYE in vacation
    # Correct vacation, if X-mas and New Year's Eve are taken off
    offdays -= 1
    # Adjust work load balance for New Year's Eve
    params["tmp"]["Xfactor"] -= 1
  end
  #* Add new vacation at the beginning of the new year
  if stop > NYE
    # Check correct balance at the end of the year,
    # if vacation starts in old year and ends in new year
    if start ≤ NYE &&
      params["tmp"]["balance"] - countbdays(params["tmp"]["calendar"], start, NYE) < 0
      @warn("too much vacation taken before end of year; check whether you are allowed to use next year's vacation",
         _module=nothing, _group=nothing, _file=nothing, _line=nothing)
    end
    # Update year and reset Xmas flag
    n = year(stop) - params["tmp"]["year"]
    params["tmp"]["year"] += n
    params["tmp"]["balance"] += n*params["Settings"]["vacation days"]
    params["tmp"]["Xmas"] = false
    # Adjust work balance at X-mas/New Year's Eve, if no vacation is taken
    @debug NYE data["stats"]["start"] data["stats"]["stop"]
    if cal.isbday(params["tmp"]["calendar"], Xmas) && data["stats"]["start"] ≤ NYE ≤ data["stats"]["stop"]
      params["tmp"]["Xmas balance"] -= params["tmp"]["Xfactor"] *
        0.5params["Settings"]["workload"]/params["Settings"]["workdays"]
    end
    @debug(params["tmp"]["year"], params["tmp"]["Xmas balance"], params["tmp"]["Xfactor"],
      cal.isbday(params["tmp"]["calendar"], Xmas))
    # Reset Xfactor for work balance corrections to next year
    params["tmp"]["Xfactor"] = 2
  end
  #* Cap vacation at vacation deadline
  if stop > params["tmp"]["deadline"]
    # Calculate unused vacation days and days in current vacation taken before the cap
    overhead = params["tmp"]["balance"] - params["tmp"]["factor"]*params["Settings"]["vacation days"]
    overlap = countbdays(params["tmp"]["calendar"], start, params["tmp"]["deadline"])
    # Cap the vacation days to maximum allowed number and print warning
    params["tmp"]["balance"] = min(params["tmp"]["factor"]*params["Settings"]["vacation days"], params["tmp"]["balance"])
    if start ≤ params["tmp"]["deadline"]
      # Correct for vacation days taken before the cap
      params["tmp"]["balance"] += max(min(overlap, overhead), 0)
      overhead -= overlap
    end
    if overhead > 0
      @warn("$overhead vacation days lost at $(params["tmp"]["deadline"])",
        _module=nothing, _group=nothing, _file=nothing, _line=nothing)
    end
    # Update deadline to next year
    params["tmp"]["deadline"] += Year(1)
  end
  #* Update balances for current vacation period
  params["tmp"]["balance"] -= offdays
  push!(days, offdays)
  push!(remaining, params["tmp"]["balance"])
  # Warn, if too much vacation is used
  params["tmp"]["balance"] > 0 || @warn(string("not enough vacation left; reduce vacation from ",
    start, " – ", stop, " and subsequent vacations this year"),
     _module=nothing, _group=nothing, _file=nothing, _line=nothing)
  return
end



"""
    check_vacationcredit(data::dict, params::dict)::Nothing

Issue infos or warnings about low or expiring vacation stored in `data` using
thresholds defined in `params`.
"""
function check_vacationcredit(data::dict, params::dict)::Nothing
  @debug "vacation credit" params["tmp"]
  # Get data about unused vacation and the deadline
  deadline = Date(year(today()), Dates.monthday(params["Settings"]["vacation deadline"])...)
  unused = data["vacation"].remaining[end] - params["tmp"]["factor"] * params["Settings"]["vacation days"]
  days_left = deadline - today()
  # Warn of vacation days running low
  if 0 < unused ≤ params["Log"]["low vacation"][2]
    @warn "vacation credit running low; $unused day left" _module=nothing _group=nothing _file=nothing _line=nothing
  elseif 0 < unused ≤ params["Log"]["low vacation"][1]
    @info "vacation credit running low; $unused day left"
  end
  # Warn of unused vacation days
  if unused > 0  && days_left < Day(params["Log"]["unused vacation"][2])
    @warn "$unused unused vacation day(s) expire at $deadline" _module=nothing _group=nothing _file=nothing _line=nothing
  elseif unused > 0  && days_left < Day(params["Log"]["unused vacation"][1])
    @info "$unused unused vacation day(s) expire at $deadline"
  end
  return
end


"""
    save_tmp!(data::dict, params::dict)::Nothing

Save parameters calculated from `params` and `data` to a `"tmp"` section in `data`.
"""
function save_tmp!(data::dict, params::dict)::Nothing
  # Current year
  params["tmp"]["year"] = year(data["stats"]["start"])
  # Parameters for vacation days
  params["tmp"]["balance"] = params["Recover"]["vacation"]
  params["tmp"]["deadline"] = params["Settings"]["vacation deadline"] + Year(data["stats"]["start"])
  params["tmp"]["factor"] = max(1, year(params["Settings"]["vacation deadline"]))
  if data["stats"]["start"] > params["tmp"]["deadline"]
    data["tmp"]["deadline"] = Date(year(data["stats"]["start"]),12,31)
  end
  # Parameters for X-mas/New Year's corrections
  params["tmp"]["Xmas"] = false
  params["tmp"]["Xfactor"] = 2
  params["tmp"]["Xmas balance"] = 0
  return
end
