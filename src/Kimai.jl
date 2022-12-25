module Kimai

using Dates
import OrderedCollections.OrderedDict as dict
import BusinessDays as cal
import YAML as yml
import CSV
import DataFrames as df
import DataFrames: DataFrame

# Ensure sessions folder
isdir(normpath(@__DIR__, "../sessions/")) || mkdir("test")
# Load source files
include("config.jl")
include("load.jl")
include("stats.jl")

end # module Kimai
