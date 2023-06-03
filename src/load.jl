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
  vacation_balance!(data, params)
  # Return Kimai data
  return data
end


"""
    load_kimai!(data::dict, params::dict)::Nothing

Load Kimai data from files defined by `params["Datasets"]` and return as `DataFrame`.
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

Load the `type` of offdays from the `"Datasets"` in `params` to a `DataFrame` and
add an entry `type` to `data`.
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
    return
  end

  ## Data processing
  # Read input file
  leave = CSV.read(abscence, DataFrame, stringtype=String, stripwhitespace=true)
  @debug leave
  # Process dates and convert to date format
  start, stop, days, reason = Date[], Date[], Int[], String[]
  for i = 1:size(leave, 1)
    # Split ranges into start and stop date
    current_date = strip.(split(leave[i, 1], "-"))
    # Process dates, use same stop date as start date for single date
    startdate = Date(current_date[1], dateformat"d.m.y")
    stopdate = length(current_date) == 1 ? startdate : Date(current_date[2], dateformat"d.m.y")
    @debug "dates" startdate stopdate data["stats"]["start"]
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
  @debug "leave" length(reason) length(start) length(stop) length(days) type
  colname = names(leave)[2]
  leave = DataFrame(;reason, start, stop, days)
  df.rename!(leave, [colname, "start", "stop", "days"])
  # Ensure, DataFrame is not empty
  nodata = isempty(leave)
  nodata && push!(leave, (type, data["stats"]["start"], data["stats"]["stop"], 0))
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
    vacation_balance!(data::dict, params::dict)::Nothing

From the settings, recover and temporary data in `params`, add a balance column to
the dataframe in `data["vacation"]` indicating the remaining vacation days and
return that column
"""
function vacation_balance!(data::dict, params::dict)::Nothing
  ## Initial setup
  # Set up new dataframe column
  balance = Int[]
  # Current year
  yr = year(params["Recover"]["log ended"])
  yr > 0 || (yr = year(data["stats"]["start"]))
  # Parameters for vacation balance
  vacation = data["vacation"]
  params["tmp"]["balance"] = params["Recover"]["vacation"]
  # Parameters for vacation deadline
  deadline_frame = year(params["Settings"]["vacation deadline"])
  # monthday(params["Settings"]["vacation deadline"]) == (12, 31) && (deadline_frame += 1)
  @debug "deadline frame" deadline_frame

  # Loop over current vacations defined saved to dataframe
  for i = 1:size(vacation, 1)
    ## Add new vacation at new year
    if year(vacation.stop[i]) > yr
      # Add new vacation for all recent years and set stop year to current year
      n = year(vacation.stop[i]) - yr
      yr += n
      params["tmp"]["balance"] += n*params["Settings"]["vacation days"]
      # For vacations expanding into the new year, check enough vacation is available in the old year
      if year(vacation.start[i]) < year(vacation.stop[i])
        days = count_leavedays(params, vacation.start[i], Date(yr - 1, 12, 31), "vacation")
        if days > params["tmp"]["balance"] - params["Settings"]["vacation days"] # ℹ Don't consider next year's vacation
          @warn(
            string(remaining_days(days - params["tmp"]["balance"] + params["Settings"]["vacation days"]),
              " too much vacation taken before end of year; check whether you are allowed to use next year's vacation"),
            _module=nothing, _group=nothing, _file=nothing, _line=nothing
          )
        end
      end
    end
    @debug "vacation after New Year's check" params["tmp"]["balance"]

    ## Cut vacation at deadline day
    deadline = Date(yr, monthday(params["Settings"]["vacation deadline"])...)
    max_vacfactor = vacation.stop[i] < deadline ? deadline_frame + 1 : deadline_frame
    # Count days in current vacation to be considered for cut-off
    days = if vacation.start[i] > deadline
      0
    elseif vacation.stop[i] ≤ deadline
      vacation.days[i]
    else
      count_leavedays(params, vacation.start[i], deadline, "vacation")
    end
    # Calculate overhead and cut-off
    overhead = params["tmp"]["balance"] - max_vacfactor*params["Settings"]["vacation days"] - days
    overhead > 0 && (params["tmp"]["balance"] -= overhead)
    log_event(params, vacation.stop[i], deadline, overhead)
    @debug "overhead" overhead max_vacfactor days
    @debug "vacation after cut-off" params["tmp"]["balance"]
    ## Check balance after vacation
    params["tmp"]["balance"] -= vacation.days[i]
    @debug "final vacation $(vacation[i, 1])" params["tmp"]["balance"]
    push!(balance, params["tmp"]["balance"])
    if params["tmp"]["balance"] < 0
      @warn(
        string("not enough vacation left; reduce vacation \"$(vacation[i,1])\" from ",
        vacation.start[i], " – ", vacation.stop[i], " by $(remaining_days(abs(params["tmp"]["balance"]))) ",
        "and cancel subsequent vacations"),
        _module=nothing, _group=nothing, _file=nothing, _line=nothing
      )
    end
  end
  ## Add balance to vacation dataframe
  vacation.balance = balance
  # Log low vacation
  log_event(params, vacation)
end


"""
    function log_event(
      params::dict,
      vacationend::Date,
      deadline::Date,
      overhead::Int
    )::Nothing

Informs or warns (based on the settings in `params`) about unused vacation (`overhead`)
on `deadline` day. The `vacationend` is used to determine whether the cut-off already
occurred in the past.
"""
function log_event(
  params::dict,
  vacationend::Date,
  deadline::Date,
  overhead::Int
)::Nothing
  # Ret
  (overhead ≤ 0 || deadline - today() > Day(params["Log"]["unused vacation"][1])) && return
  msg = "unused vacation: $(remaining_days(overhead)) expire at $deadline"
  if deadline < today() || vacationend < deadline
    @warn "$overhead vacation days were lost before $vacationend" _module=nothing _group=nothing _file=nothing _line=nothing
  elseif deadline - today() ≤ Day(params["Log"]["unused vacation"][2])
    @warn msg _module=nothing _group=nothing _file=nothing _line=nothing
  else
    @info msg _module=nothing _group=nothing _file=nothing _line=nothing
  end
end


"""
    log_event(params::dict, vacation::DataFrame)::Nothing

Informs or warns (based on the thresholds in `params`), if remaining `vacation` is
running low.
"""
function log_event(params::dict, vacation::DataFrame)::Nothing
  # Warn of vacation days running low
  unused = vacation.balance[end]
  msg = "remaining vacation low; $(remaining_days(unused)) left"
  if 0 ≤ unused ≤ params["Log"]["low vacation"][2]
    @warn msg _module=nothing _group=nothing _file=nothing _line=nothing
  elseif 0 ≤ unused ≤ params["Log"]["low vacation"][1]
    @info msg
  end
end


"""
    remaining_days(d::Int)::String

Return a String `d day(s)` using the correct grammatical form.
"""
remaining_days(d::Int)::String = d == 1 ? "1 day" : string(d, " days")
