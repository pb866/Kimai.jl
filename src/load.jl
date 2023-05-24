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
  load_kimai!(data, params)
  # Set current Kimai period for restriction
  data["stats"] = dict{String,Any}(
    "start" => data["kimai"].in[end],
    "stop" => data["kimai"].out[1]
  )
  @debug "init stop date" data["stats"]["stop"]

  # Initialise data sets and calendars for leave days
  params["tmp"]["vacation"] = dict("calendar" => Vacation(), "dates" => Set())
  params["tmp"]["sickdays"] = dict("calendar" => SickLeave(), "dates" => Set())
  params["tmp"]["halfdays"] = HalfDay()
  # Load leave days
  load_abscence!(data, params, "sickdays")
  load_abscence!(data, params, "vacation")
  @debug "refined stop date" data["stats"]["stop"]
  # Check vacation, issue warnings for low credit/unused vacation
  # TODO check_vacationcredit(data, params)
  # Return Kimai data
  return data
end


"""
    load_kimai!(data::dict, params::dict)::Nothing

Load input data from files defined by `params["Datasets"]` and return as `DataFrame`.
"""
function load_kimai!(data::dict, params::dict)::Nothing
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
  # Save data and return
  data["kimai"] = kimai
  return
end


"""
    load_abscence!(
      data::dict,
      params::dict,
      type::String
    )::Nothing

Load the `type` of offdays from the `"Datasets"` in `params` to a `DataFrame`,
add an entry `type` to `data`, and return the `DataFrame`.
"""
function load_abscence!(
  data::dict,
  params::dict,
  type::String
)::Nothing
# Check: empty file
# Check: missing file
  ## Argument checks/setup
  # Get current off-day type
  abscence = params["Datasets"][type]
  @debug "abscence source" type abscence
  if isempty(abscence)
    # Return empty DataFrame with default columns for non-existing files
    data[type] =  DataFrame(
      reason=String[type],
      start=Date[data["stats"]["start"]],
      stop=Date[data["stats"]["stop"]],
      days=Int[0]
    )
    #=
    # Solution > moved to separate function after loading general data
    if type == "vacation"
      data[type].remaining = Int[params["Settings"]["vacation days"]]
      save_tmp!(data, params)
    end
    =#
    return
  end
  ## Data processing
  # Read input file
  leave = CSV.read(abscence, DataFrame, stringtype=String, stripwhitespace=true)
  # Setup balance and deadline parameters for vacation
  # Fix move to new function
  # type == "vacation" && save_tmp!(data, params)
  # Process dates and convert to date format
  start, stop, days, reason = Date[], Date[], Int[], String[]
  # Solution > remaining = Int[] moved to new function
  for i = 1:size(leave, 1)
    # Split ranges into start and stop date
    current_date = strip.(split(leave[i, 1], "-"))
    # Process dates, use same stop date as start date for single date
    startdate = Date(current_date[1], dateformat"d.m.y")
    stopdate = length(current_date) == 1 ? startdate : Date(current_date[2], dateformat"d.m.y")
    # Ignore past dates
    startdate > data["stats"]["start"] || continue
    # Save dates of complete period, reason, and the number of leave days
    # Leave day count at the edges is restricted to within start and stop date
    push!(start, startdate)
    push!(stop, stopdate)
    push!(reason, leave[i, 2])
    push!(days, count_leavedays(params, startdate, stopdate, type))
    if startdate ≤ data["stats"]["stop"] && stopdate > data["stats"]["stop"]
      # Correct stop date for later balance calculation,
      # if off-day period partly overlaps with end of Kimai period
      data["stats"]["stop"] = DateTime(stopdate, Time(23,59,59))
    end
  end

  # Add leave days to dataset
  @debug "leave" length(reason) length(start) length(stop) length(days) type # fix remove length(remaining), if remaining is calculated in new function
  colname = names(leave)[2]
  leave = DataFrame(;reason, start, stop, days)
  df.rename!(leave, [colname, "start", "stop", "days"])
  # Ensure, DataFrame is not empty
  nodata = isempty(leave)
  nodata && push!(leave, (type, data["stats"]["start"], data["stats"]["stop"], 0))
  # Add remaining vacation days
  #=
  # Solution: moved to new function
  if type == "vacation"
    @debug "vacation" [params["Settings"]["vacation days"]] leave
    leave.remaining = nodata ? [params["Settings"]["vacation days"]] : remaining
  end
  =#
  # Save data and add balance counter for vacation
  data[type] = leave
  return
end


"""
    count_leavedays(params::dict, start::Date, stop::Date, type::String)::Int

Count the number of leave days of given `type` between `start` and `stop`.
Save the dates in `params` and return number of leave days as Int.

If the Xmas rule is applied and an odd number of half-days exists in the vacation period,
leave is rounded up to full days, unless a left-over half-day from previous vacations
exists. In this case, leave is rounded down to the next smaller number (as the existing
half-day would be considered for this leave period).
"""
function count_leavedays(params::dict, start::Date, stop::Date, type::String)::Int
  # Set leave of given `type` in temporary calendar and save number of leave days
  leave = listworkdays(params, start, stop, type)
  union!(params["tmp"][type]["dates"], leave)
  days = length(leave)
  # Optionally apply Xmas rule to annual leave
  if type == "vacation" && params["Settings"]["Xmas rule"]
    # Get number of halfdays, use remainder for uneven days to reduce current vacation, if uneven
    halfdays = length(intersect(cal.listholidays(params["tmp"]["halfdays"], start, stop), leave))/2 -
      0.5params["Recover"]["halfday"]
    # Correct number of leave days
    days -= round(halfdays, RoundDown)
  end
  return days
end


"""
# ¡obsolete! #
    vacationaccout!(
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
  # DONE Add offdays and return for non-vacation types
  offdays = countbdays(params["tmp"]["calendar"], start, stop)
  if type != "vacation"
    push!(days, offdays)
    return
  end
  # DONE Apply X-mas rule
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
  # TODO Add new vacation at the beginning of the new year
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
  # TODO Cap vacation at vacation deadline
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
  # TODO Update balances for current vacation period
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
# fix > Rename to vacation_credit! or set_vacationcredit
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
#¿Still needed?#
"""
function save_tmp!(data::dict, params::dict)::Nothing
  # Current year
  params["tmp"]["year"] = year(data["stats"]["start"])
  # Parameters for vacation days
  params["tmp"]["balance"] = params["Recover"]["vacation"]
  params["tmp"]["deadline"] = params["Settings"]["vacation deadline"] + Year(data["stats"]["start"])
  # params["tmp"]["factor"] = max(1, year(params["Settings"]["vacation deadline"]))
  # ¿Set elsewhere?
  if data["stats"]["start"] > params["tmp"]["deadline"]
    data["tmp"]["deadline"] = Date(year(data["stats"]["start"]),12,31)
  end
  # Parameters for X-mas/New Year's corrections
  #// params["tmp"]["Xmas"] = false
  #// params["tmp"]["Xfactor"] = 2
  #// params["tmp"]["Xmas balance"] = 0
  return
end
