## Get important information from config.yaml and store in dictionaries settings, files, and recover


# """


# """
# function configure()
  # Read config.yaml
  # Set parameters
  # restore last session from log
# end

"""
    configure(
      config::String="";
      recover::Union{Bool,Symbol}=true,
      kwargs...
    ) -> settings, datasets, recover

From the `config` file, read important parameters and settings as well as information
about the time log, vacation, and sick leave datasets. If true, `recover` previous balances
until the last date processed.

Parameters not defined in the `config` yaml file will be filled with defaults.
All parameters can be overwritten with the following kwargs:

- `state`: Ferderal state of Germany, which holidays will be applied.
- `workload`: Work hours per week as agreed in the contract.
- `workdays`: Number of work days in a week as in the work contract.
- `vacation_days`: Number of vacation days per year as in the work contract.
- `vacation_deadline`: Day of the year (either as String `"dd.mm."`, if the deadline
  falls in the next year, or as Date, where the year is the number of years after
  the year your vacation was granted), e.g. use:
  - 0000-12-31, if you have to take all your vacation in the same year
    (no String possible or use "1.1.", which is technically the same,
    if you don't have to work on holidays)
  - 0001-03-31 (or "31.3." or "31.03."), if you have to use your vacation by 31. March of the next year
  - 9999-12-31, if you don't have a limit, when your vacation needs to be taken
- `finalyear`: last year in your Kimai history (first line of file, which should be
  listed anti-chronological), by default the modification date of the Kimai file is used
- `dir`: directory, where all your dataset files are stored
  (can be overwritten by passing the directory plus file name in the follwoing arguments)
- `kimai`: file name (and optionally directory) of the Kimai time log
- `vacation`: file name (and optionally directory) of the vacation dataset or, optionally,
  number of vacation days already taken
- `sickness`: file name (and optionally directory) of the sick leave dataset or, optionally,
  number of sick days in the current year
"""
function configure(
  config::String="";
  recover::Union{Bool,Symbol}=true,
  kwargs...
)

  ## Read config file
  data = isempty(config) ? dict() : try
    yml.load_file(config, dicttype=dict)
  catch
    @warn "Config file not found. Values from kwargs and defaults used."
    dict()
  end

  # Recover last session
  prev_session = recover_session(recover, data)

  ## Datasets and sources
  # Ensure, Datasets section exists in data
  haskey(data, "Datasets") || (data["Datasets"] = dict())
  # Init new ordered dict to ensure preferred order:
  datasets = dict()
  # Fill dict
  add_dictentry!(datasets, "dir", data["Datasets"], kwargs, ".")
  add_dictentry!(datasets, "kimai", data["Datasets"], kwargs, "export.csv")
  add_dictentry!(datasets, "vacation", data["Datasets"], kwargs, "vacation.csv")
  add_dictentry!(datasets, "sickness", data["Datasets"], kwargs, "sickness.csv")
  # Check files and standardise dict entries
  datasets["kimai"] = normfiles(datasets["kimai"], datasets["dir"], mandatory=true)
  datasets["vacation"] isa Int || (datasets["vacation"] = normfiles(datasets["vacation"], datasets["dir"]))
  datasets["sickness"] isa Int || (datasets["sickness"] = normfiles(datasets["sickness"], datasets["dir"]))

  ## General settings
  # Ensure, Settings section exists in data
  haskey(data, "Settings") || (data["Settings"] = dict())
  # Init new ordered dict to ensure preferred order:
  settings = dict()
  # Fill dict
  add_dictentry!(settings, "state", data["Settings"], kwargs, "SN")
  add_dictentry!(settings, "workload", data["Settings"], kwargs, 40)
  add_dictentry!(settings, "workdays", data["Settings"], kwargs, 5)
  add_dictentry!(settings, "vacation days", data["Settings"], kwargs, 30)
  add_dictentry!(settings, "vacation deadline", data["Settings"], kwargs, Date(0001, 03, 31))
  default = year(unix2datetime(mtime(datasets["kimai"])))
  default == 1970 && (default = year(today()))
  add_dictentry!(settings, "finalyear", data["Settings"], kwargs, default)

  # Return revised session parameters
  settings, datasets, prev_session
end


"""
    add_dictentry!(database::dict, label::String, rawdata::dict, kwargs, default)

Add an entry defined by a `label` to the `database` from the `rawdata` with the same `label`.
Overwrite `rawdata` with `kwargs`, if provided, or use `default` values for missing data.
"""
function add_dictentry!(database::dict, label::String, rawdata::dict, kwargs, default)
  # sym = Symbol(replace(label, " " => "_"))
  sym = Symbol(join(split(label), "_"))
  database[label] = if haskey(kwargs, sym)
    kwargs[sym]
  elseif !haskey(rawdata, label) || isnothing(rawdata[label])
    default
  elseif default isa Date && rawdata[label] isa Date
    rawdata[label] + Year(today())
  elseif default isa Date && rawdata[label] isa String
    Date(rawdata[label]*string(year(today()) + 1), dateformat"d.m.y")
  else
    rawdata[label]
  end
end


"""
    normfiles(file::AbstractString, dir::AbstractString; mandatory=false, abs=false)::String

Add the `dir`ectory to the `file`, if the `file` does not already include a folder path.
Convert the `file` string to an absolute path, if `abs` is set to `true`.
Give a warning for missing files or throw an error, if the file is `mandatory`.
"""
function normfiles(file::AbstractString, dir::AbstractString; mandatory=false, abs=false)::String
  # Get file including folder path (and convert to absolute path, if desired)
  file = contains(file, '/') ? normpath(file) : normpath(dir, file)
  abs && (file = abspath(file))
  # Check file exists and warn or throw error for mandatory files
  if !isfile(file) && mandatory
    throw(@error "$file does not exist")
  elseif !isfile(file)
    @warn "$file does not exist; data ignored"
    file = ""
  end

  return file
end


"""
true/false/session name; allow in in config.yaml or kwarg only?
  if true:  - starts new session with info about no recoverable session
            - uses session, if only one session available
            - asks, which session to use, if several sessions available
  if session name: uses session or throws warnings with `true` behaviour
  if false: starts new session

Return dict with
Recover:
  log ended: 2022-03-31 23:59:59
  balance: [14.5, {Day: 1, Hour: 6, Minute: 30}]
  vacation: 7
  sickness: 0

"""
function recover_session(recover, data)
  return dict()
end

