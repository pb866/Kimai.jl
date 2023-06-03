module Kimai

## Import packages
using Dates
import Logging
import OrderedCollections.OrderedDict as dict
import BusinessDays as cal
import YAML as yml
import CSV
import DataFrames as df
import DataFrames: DataFrame

#* Ensure sessions folder
sessions = normpath(@__DIR__, "../sessions/")
isdir(sessions) || mkdir(sessions)

## Load source files
include("config.jl")
include("load.jl")
include("stats.jl")

## Calendar tasks
# Define custom calendars for sick, annual leave, and half workdays
struct Vacation <: cal.HolidayCalendar end
struct SickLeave <: cal.HolidayCalendar end
struct HalfDay <: cal.HolidayCalendar end

cal.isholiday(::Vacation, d::Date) = d in params["tmp"]["vacation"]["dates"]
cal.isholiday(::SickLeave, d::Date) = d in params["tmp"]["sickdays"]["dates"]
cal.isholiday(::HalfDay, d::Date) = month(d) == 12 && (day(d) == 24 || day(d) == 31)

#=
#* Define interface functions to count work, vacation, and sick-days
#* that use count_workdays under the hood
# Issue: rename count_workdays (to countdays or count_calendardays?) to acknowledge counting of leave days
# * count_workdays(start, stop, params)
# * count_sickdays(start, stop, params)
# * count_vacation(start, stop, params)
=#

 end # module Kimai
