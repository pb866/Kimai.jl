# Load data from input files

"""
    load(params::dict, restrict::Bool=true)::dict

Load Kimai, vacation, and sickdays data from the files defined in `params` and
return as ordered dict with entries `"kimai"`, `"vacation"`, and `"sickdays"`.

By default, only vacation and sick days within the Kimai period are counted. If
future and past off-days should be considered, set `restrict` to false.
"""
function load(params::dict, restrict::Bool=true)::dict
  # Initialise dict
  data = dict()
  # Load Kimai times
  data["kimai"] = load_kimai(params)
  # Set current Kimai period for restriction
  data["stats"] = dict{String,Any}(
    "start" => DateTime(max(data["kimai"].in[end], params["Recover"]["log ended"])),
    "stop" => DateTime(data["kimai"].out[1])
  )
  start = restrict ? data["stats"]["start"] : Date(-9999)
  stop = restrict ? data["stats"]["stop"] : Date(9999)
  # Load off-days
  load_offdays!(data, params, "vacation"; start, stop)
  load_offdays!(data, params, "sickdays"; start, stop)
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

  # Convert Date and times
  kimai.date .*= string(params["Settings"]["finalyear"])
  kimai.date = Date.(kimai.date, dateformat"d.m.y")
  # Convert dates
  [kimai.date[i] > kimai.date[i-1] && (kimai.date[i:end] .-= Year(1)) for i = 2:length(kimai.date)]
  kimai.in = DateTime.(kimai.date, kimai.in)
  kimai.out = DateTime.(kimai.date, kimai.out)
  # Reduce data to current session
  i = findfirst(kimai.out .< params["Recover"]["log ended"])
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
  type::String;
  start::DateTime=DateTime(-9999),
  stop::DateTime=Date(9999)
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
  offdays = CSV.read(off, DataFrame, stringtype=String)
  # Process dates and convert to date format
  offstart, offend, count = Date[], Date[], Int[]
  for date in offdays[!, 1]
    # Split ranges into start and stop date
    current_date = strip.(split(date, "-"))
    # Process dates, use same stop date as start date for single date
    startdate = Date(current_date[1], dateformat"d.m.y")
    stopdate = length(current_date) == 1 ? startdate : Date(current_date[2], dateformat"d.m.y")
    push!(offstart, startdate)
    push!(offend, stopdate)
    # Count the offdays of current period within start and stop (if given)
    startdate = startdate > stop ? stop + Day(1) : min(stop, max(start, startdate))
    stopdate = stopdate < start ? start - Day(1) : min(stop, max(start, stopdate))
    push!(count, countbdays(cal.DE(:SN), Date(startdate), Date(stopdate)))
  end
  # Clean up dataframe
  offdays[!, "start"] = offstart
  offdays[!, "stop"] = offend
  offdays[!, "count"] = count
  offdays[!, 2] = strip.(offdays[!, 2])
  df.select!(offdays, df.Not(1))
  # Add offdays to dataset
  data[type] = offdays
  return offdays
end
