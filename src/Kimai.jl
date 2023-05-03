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

end # module Kimai
