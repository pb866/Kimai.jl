# Load data from input files

"""
    load(params::dict, restrict::Bool=true)::dict

Load Kimai, vacation, and sickness data from the files defined in `params` and
return as ordered dict with entries `"kimai"`, `"vacation"`, and `"sickness"`.

By default, only vacation and sick days within the Kimai period are counted. If
future and past off-days should be considered, set `restrict` to false.
"""
function load(params::dict, restrict::Bool=true)::dict
  # Initialise dict
  data = dict()
  # Load Kimai times
  data["kimai"] = load_kimai(params)
  # Current Kimai period for restriction
  start = restrict ? Date(max(data["kimai"].in[end], params["Recover"]["log ended"])) : Date(-9999)
  stop = restrict ? Date(data["kimai"].out[1]) : Date(9999)
  # Load off-days
  data["vacation"] = load_offdays(params, "vacation"; start, stop)
  data["sickness"] = load_offdays(params, "sickness"; start, stop)
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
  # Return kimai dataframe
  return kimai
end


"""
    load_offdays(params::dict, type::String)::DataFrame

Load the `type` of offdays from the `"Datasets"` in `params` to a `DataFrame`
and return it.
"""
function load_offdays(params::dict, type::String; start::Date=Date(-9999), stop::Date=Date(9999))::DataFrame
  # Return empty DataFrame with default columns for non-existing files
  file = params["Datasets"][type]
  isempty(file) && return DataFrame(reason=String[], start=Date[], stop=Date[], count=Int[])
  # Read input file
  offdays = CSV.read(file, DataFrame, stringtype=String)
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
    push!(count, countbdays(cal.DE(:SN), startdate, stopdate))
  end
  # Clean up dataframe
  offdays[!, "start"] = offstart
  offdays[!, "stop"] = offend
  offdays[!, "count"] = count
  offdays[!, 2] = strip.(offdays[!, 2])
  df.select!(offdays, df.Not(1))
  # Return dataframe
  return offdays
end
