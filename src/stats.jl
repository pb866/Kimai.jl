## helper functions to process times/periods and calculate balances
## Conversion of time units

""" Convert hours to milliseconds """
htoms(h::Real) = 3_600_000h


""" Convert ms to days """
mstoday(ms::Real, rounding_mode::RoundingMode=RoundNearestTiesUp)::Int = round(Int, ms/86_400_000, rounding_mode)


## Calculate balances

"""
    arm!(params::dict, restrict::Bool=true)::dict

Load time logs from the files defined in `params` and return a dictionary with
entries for `"kimai"` `"vacation"`, and `"sickdays"` data together with `"stats"`
about work- and off-days and balances.
"""
function arm!(params::dict)::dict
  data = load!(params)
  calculate!(data, params)
  return data
end


"""
    calculate!(data::dict, params::dict)::dict

Calculate balances in the `data` and add together with other statistics to
a new `data` entry `"stats"`. Positive balances mean overtime delivered,
negative times mean work due. Return the new entry as ordered `dict`.
"""
function calculate!(data::dict, params::dict)::dict
  # Initialise
  cal.initcache(params["tmp"]["calendar"])
  # Count work and off days
  total = countbdays(cal.NullHolidayCalendar(),
    Date(data["stats"]["start"]), Date(data["stats"]["stop"]))
  target = countbdays(params["tmp"]["calendar"], Date(data["stats"]["start"]), Date(data["stats"]["stop"]))
  holidays = countholidays(params["tmp"]["calendar"], Date(data["stats"]["start"]), Date(data["stats"]["stop"]))
  rows = findall(≤(Date(data["stats"]["stop"])), data["vacation"].stop)
  @debug "rows" Date(data["stats"]["stop"]) data["vacation"].stop rows
  current_vacation = @view data["vacation"][rows, :]
  @debug "vacation" data["vacation"]
  vacation = sum(current_vacation.days)
  rows = findall(≤(Date(data["stats"]["stop"])), data["sickdays"].stop)
  current_sickdays = @view data["sickdays"][rows, :]
  sickdays = sum(current_sickdays.days)
  weekends = total - target - holidays
  # Calculate workload and balance and add stats entry to data
  workdays = target - vacation - sickdays
  workload = daystoworkms(Day(workdays), params) + Dates.toms(Hour(params["tmp"]["Xmas balance"]))
  balance = Dates.toms(sum(data["kimai"].time)) - workload + params["Recover"]["balance"]
  merge!(data["stats"], dict(
    "total days" => total,
    "target days" => target,
    "workdays" => workdays,
    "vacation" => vacation,
    "sickdays" => sickdays,
    "holidays" => holidays,
    "weekends" => weekends,
    "workload" => workload,
    "balance" => balance # + params["Recover"]["balance"] here or during show
  ))
  # Correct for Xmas rule, if option is selected
  applyXmasrule!(data["stats"], params)
end


function applyXmasrule!(stats::dict, params::dict)::dict
  # Count Xmas and New Year's Eve days in current time span
  timespan = Date(stats["start"]):Day(1):Date(stats["stop"])
  Xmas = count([Date(year,12,24) ∈ timespan && cal.isbday(params["tmp"]["calendar"], Date(2024,12,24)) for year in year(stats["start"]):year(stats["stop"])])
  NYE = count([Date(year,12,31) ∈ timespan && cal.isbday(params["tmp"]["calendar"], Date(2024,12,31)) for year in year(stats["start"]):year(stats["stop"])])

  # Define correction factors for full days (in days) and half days (in ms)
  Xhalf, Xfull = modf((Xmas + NYE)/2)
  Xhalf *= htoms(params["Settings"]["workload"]/params["Settings"]["workdays"])
  @debug "Xmas rule" Xhalf  Xfull
  begin
    println("original stats")
    for key in stats.keys
      println(key, " = ", stats[key])
    end
  end

  # Correct stats
  stats["target days"] -= 1
  stats["workdays"] -= 1
  stats["holidays"] += 1
  stats["workload"] -= (daystoworkms(Day(Xfull), params) + Xhalf)
  stats["balance"] += (daystoworkms(Day(Xfull), params) + Xhalf)
  # Save flag, if period contains half day
  params["tmp"]["Xhalf"] = Bool(mstoday(Xhalf, RoundUp))
  @debug begin
    println("corrected stats")
    for key in stats.keys
      println(key, " = ", stats[key])
    end
  end

  # Return corrected stats (in addition to in-place corrections)
  return stats
end


"""
    worktime(milliseconds::Real, params::dict; show_weeks::Bool=false)::Dates.CompoundPeriod

From the `milliseconds` (as `Real`) return a `CompoundPeriod`.
The `CompoundPeriod` contains a maximum of hours, minutes, and seconds/milliseconds
as the contracted workload per day.
Days are redefined as workdays containing the time as defined by the contract (workload/workdays).
If `show_weeks` is set to true, weeks are shown as number of workdays defined in `params`.
"""
function worktime(milliseconds::Real, params::dict; show_weeks::Bool=false)::Dates.CompoundPeriod
  # Optionally calculate number of "workweeks"
  w, rem_time = if show_weeks
    divrem(milliseconds, htoms(params["Settings"]["workload"]))
  else
    0, milliseconds
  end
  # Calculate work-time
  d, rem_time = divrem(rem_time, htoms(params["Settings"]["workload"]/params["Settings"]["workdays"]))
  h, rem_time = divrem(rem_time, htoms(1))
  m, rem_time = divrem(rem_time, 60_000)
  s, ms = divrem(rem_time, 1000)

  # Construct a CompoundPeriod
  Week(w) + Day(d) + Hour(h) + Minute(m) + Second(s) + Millisecond(ms)
end


"""
    daystoworkms(days::Day, params::dict)::Millisecond

Convert `days` to a workday, which is defined by the `workload` devided by the number
of `workdays` in `params`, and return the result in `Millisecond`.
"""
function daystoworkms(days::Day, params::dict)::Real
  htoms(days.value*params["Settings"]["workload"]/params["Settings"]["workdays"])
end


"""
    countbdays(calendar::cal.HolidayCalendar, start::Date, stop::Date)::Int

Return the number of business days within the `start` and `stop` date (including both edges)
using the `calender` of a specified region. `0` days are returned for ranges, where
the `start` date is later than the `stop` date.
"""
function countbdays(calendar::cal.HolidayCalendar, start::Date, stop::Date)::Int
  start > stop ? 0 : length(cal.listbdays(calendar, start, stop))
end


"""
    countholidays(calendar::cal.HolidayCalendar, start::Date, stop::Date)::Int

Return the number of holidays within the `start` and `stop` date (including both edges)
using the `calender` of a specified region. `0` days are returned for ranges, where
the `start` date is later than the `stop` date.
"""
function countholidays(calendar::cal.HolidayCalendar, start::Date, stop::Date)::Int
  start > stop ? 0 : length(cal.listholidays(calendar, start, stop))
end
