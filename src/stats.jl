# Conversion of time units
""" Convert hours to milliseconds """
htoms(h::Real) = 3_600_000h
""" Convert milliseconds to hours """
mstoh(ms::Real) = h/3_600_000


# Calculate balances; helper functions to process times/periods

"""
    arm(params::dict, restrict::Bool=true)::dict

Load time logs from the files defined in `params` and return a dictionary with
entries for `"kimai"` `"vacation"`, and `"sickdays"` data together with `"stats"`
about work- and off-days and balances.

By default, only vacation and sick days within the Kimai period are considered.
If `restrict` is set to `false`, all vacation and sick days defined in the respective
files are counted.
"""
function arm(params::dict, restrict::Bool=true)::dict
  data = load(params)
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
  # Count work and off days
  total = countbdays(cal.NullHolidayCalendar(),
    Date(timelog["stats"]["start"]), Date(timelog["stats"]["stop"]))
  target = countbdays(country, Date(timelog["stats"]["start"]), Date(timelog["stats"]["stop"]))
  holidays = countholidays(country, Date(timelog["stats"]["start"]), Date(timelog["stats"]["stop"]))
  vacation = sum(timelog["vacation"].count)
  sickdays = sum(timelog["sickdays"].count)
  weekends = total - target - holidays
  # Calculate workload and balance and add stats entry to timelog
  workdays = target - vacation - sickdays
  workload = daystoworkms(Day(workdays), params)
  balance = Dates.toms(sum(timelog["kimai"].time)) - workload
  merge!(timelog["stats"], dict(
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
