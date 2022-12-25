# Calculate balances; helper functions to process times/periods

"""
    arm(params::dict, restrict::Bool=true)::dict

Load time logs from the files defined in `params` and return a dictionary with
entries for `"kimai"` `"vacation"`, and `"sickness"` data together with `"stats"`
about work- and off-days and balances.

By default, only vacation and sick days within the Kimai period are considered.
If `restrict` is set to `false`, all vacation and sick days defined in the respective
files are counted.
"""
function arm(params::dict, restrict::Bool=true)::dict
  data = load(params, restrict)
  calculate!(data, params)
  return data
end


"""
    calculate!(timelog::dict, params::dict)::dict

Calculate the balance in the `timelog` and add together with other statistics to
an new `timelog` entry `"stats"`. Positive balances mean overtime delivered,
negative times mean work due. Return the new entry as ordered `dict`.
"""
function calculate!(timelog::dict, params::dict)::dict
  # Initialise
  country = cal.DE(Symbol(params["Settings"]["state"]))
  cal.initcache(country)
  start = Date(max(timelog["kimai"].in[end], params["Recover"]["log ended"]))
  stop = Date(timelog["kimai"].out[1])
  # Count work and off days
  workload = countbdays(country, start, stop)
  holidays = sum(timelog["vacation"].count)
  sickdays = sum(timelog["sickness"].count)
  weekends = countbdays(cal.NullHolidayCalendar(), start, stop) - workload - holidays
  # Calculate workload and balance and add stats entry to timelog
  work = workload - holidays - sickdays
  workdays = daystoworkms(Day(work), params)
  balance = Dates.toms(sum(timelog["kimai"].time)) - workdays
  timelog["stats"] = dict(
    "workdays" => workdays,
    "holidays" => holidays,
    "sickdays" => sickdays,
    "weekends" => weekends,
    "workload" => workload,
    "balance" => balance
  )
end


"""
    worktime(milliseconds::Real, params; show_weeks::Bool=false)::Dates.CompoundPeriod

From the `milliseconds` (as `Real`) return a `CompoundPeriod`.
The `CompoundPeriod` contains a maximum of hours, minutes, and seconds/milliseconds
as the contracted workload per day.
Days are redefined as workdays containing the time as defined by the contract (workload/workdays).
If `show_weeks` is set to true, weeks are shown as number of workdays defined in `params`.
"""
function worktime(milliseconds::Real, params; show_weeks::Bool=false)::Dates.CompoundPeriod
  # Conversion factor hours to ms
  hms = 3_600_000
  # Get workday in ms from params
  wday = params["Settings"]["workload"]/params["Settings"]["workdays"]
  wday_ms = wday * hms
  # Calculate work time for units hours and smaller
  hours, rem_time = workhours(milliseconds, wday)
  # Check that current units do not exceed a workday
  # otherwise recalculate with corrected values and add larger units (days/weeks)
  worktime_correction = Dates.toms(hours) - wday_ms
  if worktime_correction > 0
    hours, rem_time_correction = workhours(worktime_correction, wday)
    days = workdays(rem_time*hms + rem_time_correction*hms + wday_ms/wday, params; show_weeks)
  else
    days = workdays(rem_time*hms, params; show_weeks)
  end

  return days + hours
end


"""
    workhours(milliseconds::Real, workhours::AbstractFloat)::Tuple{Dates.CompoundPeriod,Real}

From the milliseconds given as `Real`, return a `CompoundPeriod` including
`hours`, `minutes`, `seconds`, and `milliseconds` and the remaining time in
`milliseconds` as `Real`. To calculate the `hours` and remaining the
`workhours` per day are needed.
"""
function workhours(milliseconds::Real, workhours::AbstractFloat)::Tuple{Dates.CompoundPeriod,Real}
  rem_time, msec = divrem(milliseconds, 1000)
  ms = Millisecond(msec)
  rem_time, sec = divrem(rem_time, 60)
  s = Second(sec)
  rem_time, mins = divrem(rem_time, 60)
  m = Minute(mins)
  rem_time, hours = divrem(rem_time, workhours)
  h = Hour(hours)
  return h + m + s + ms, rem_time
end


"""
    workdays(milliseconds, params; show_weeks::Bool=false)::Dates.CompoundPeriod

From the milliseconds given as `Real`, return a `CompoundPeriod` including
`days`, and if `show_weeks` is set to `true`, `weeks`. Days and weeks are redefined
as workdays and workweeks from the `workload` and `workdays` in the `params`, i.e.
a workday is defined as `workload` divided by number of `workdays` and a workweek
consists of the number of workdays. Workweeks are only shown, if `show_weeks` is
set to `true`.
"""
function workdays(milliseconds, params; show_weeks::Bool=false)::Dates.CompoundPeriod
  rem_time = div(milliseconds, 3_600_000)
  if show_weeks
    weeks, days = divrem(rem_time, params["Settings"]["workdays"])
    return Week(weeks) + Day(days)
  else
    return Day(rem_time)
  end
end


"""
    daystoworkms(days::Day, params::dict)::Millisecond

Convert `days` to a workday, which is defined by the `workload` devided by the number
of `workdays` in `params`, and return the result in `Millisecond`.
"""
function daystoworkms(days::Day, params::dict)::Real
  days.value*params["Settings"]["workload"]/params["Settings"]["workdays"]*3_600_000
end


"""
    countbdays(calendar::cal.HolidayCalendar, start::Date, stop::Date)::Int

Return the number of business days within the `start` and `stop` date (including both edges)
using the `calender` of a specified region. `0` days are returned for ranges, where
the start date is later than the stop date.
"""
function countbdays(calendar::cal.HolidayCalendar, start::Date, stop::Date)::Int
  start > stop ? 0 : length(cal.listbdays(calendar, start, stop))
end
