# Load data from input files


"""
    load_kimai(params::dict)::DataFrame

Load input data from files defined by `params["Datasets"]` and return as `DataFrame`.
"""
function load_kimai(params::dict)::DataFrame
  # Read Kimai history
  kimai = CSV.read(params["Datasets"]["kimai"], DataFrame, select=collect(1:5))
  df.rename!(kimai, ["date", "in", "out", "time", "hours"])
  # Convert working hours and rename column
  kimai.time = Dates.canonicalize.(kimai.time-Time(0))

  # Convert Date and times
  kimai.date .*= string(params["Settings"]["finalyear"])
  kimai.date = Date.(kimai.date, dateformat"d.m.y")
  kimai.date[3:end] .+= Year(2)
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
function load_offdays(params::dict, type::String)::DataFrame
  # Read input file
  offdays = CSV.read(params["Datasets"][type], DataFrame)
  # Process dates and convert to date format
  offstart, offend = Date[], Date[]
  for date in offdays[!, 1]
    current_date = strip.(split(date, "-"))
    startdate = Date(current_date[1], dateformat"d.m.y")
    push!(offstart, startdate)
    push!(offend, length(current_date) == 1 ? startdate : Date(current_date[2], dateformat"d.m.y"))
  end
  # Clean up dataframe
  offdays[!, "begin"] = offstart
  offdays[!, "end"] = offend
  offdays[!, 2] = strip.(offdays[!, 2])
  df.select!(offdays, df.Not(1))
  # Return dataframe
  return offdays
end
