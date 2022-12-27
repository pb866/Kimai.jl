# Load data from input files

"""
    load(params::dict, restrict::Bool=true)::dict

Load Kimai, vacation, and sickdays data from the files defined in `params` and
return as ordered dict with entries `"kimai"`, `"vacation"`, and `"sickdays"`.

By default, only vacation and sick days within the Kimai period are counted. If
future and past off-days should be considered, set `restrict` to false.
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
      type::String;
      start::Date=Date(-9999),
      stop::Date=Date(9999)
    )::DataFrame

Load the `type` of offdays from the `"Datasets"` in `params` to a `DataFrame`,
add an entry `type` to `data`, and return the `DataFrame`. Only off-days within
the `start` and `stop` day are counted (borders included).
"""
function load_offdays!(
  data::dict,
  params::dict,
  type::String
)::DataFrame
  # Return empty DataFrame with default columns for non-existing files
  @show type
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
    @show startdate, data["stats"]["start"]
    stopdate > data["stats"]["start"] || continue
    # Save dates of complete of period, reason, and the number of offdays
    # Offday count at the edges is restricted to within start and stop date
    push!(start, startdate)
    push!(stop, stopdate)
    push!(reason, offdays[i, 2])
    push!(count, countbdays(cal.DE(:SN), Date(max(data["stats"]["start"], startdate)),
      Date(min(data["stats"]["stop"], stopdate))))
  end
  # Add offdays to dataset
  colname = names(offdays)[2]
  data[type] = DataFrame(colname = reason; start, stop, count)
  return data[type]
end
