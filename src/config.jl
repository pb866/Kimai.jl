## Get general settings and previous balances from config.yaml and store in dict

# Overload base function to check for empty symbols
""" Check for empty Symbol (Symbol("")) """
Base.isempty(s::Symbol) = s == Symbol("") ? true : false


# Configure Kimai session
"""
    configure(
      config::String="";
      recover::Union{Bool,Symbol}=true,
      kwargs...
    )::dict

From the `config` file, read important parameters and settings as well as information
about the time log, vacation, and sick leave datasets. If true or defined by a `Symbol`
of the session name, `recover` previous balances until the last date processed.

Parameters not defined in the `config` yaml file will be filled with defaults.
All parameters can be overwritten with the following kwargs:

- `state`: Federal state of Germany, which holidays will be applied.
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
- `sickdays`: file name (and optionally directory) of the sick leave dataset or, optionally,
  number of sick days in the current year

Furthermore, balances of the last session can be tweaked, which can be useful for the first
time, when a new position is started.

- `balance`: Use either
  - `Real` (`Float` or `Int`) for previously worked hours or
  - `Period` or `CompoundPeriod` for previously worked time
- `vacation_balance` (`Int`): Number of vacation days already taken
- `sickdays_balance` (`Int`): Number of sick leave days previously taken

The order, in which parameters are selected is:
1. kwargs
2. config.yaml
3. recover data or defaults
"""
function configure(
  config::String="";
  recover::Union{Bool,Symbol}=true,
  kwargs...
)::dict
  ## Read config file
  params = isempty(config) ? dict() : try
    yml.load_file(config, dicttype=dict)
  catch
    @warn "Config file not found or corrupt. Values from kwargs and defaults used."
    dict()
  end

  ## Recover last session
  recover_session!(params, recover)
  check_dictentry!(params["Recover"], "log ended", kwargs, DateTime, DateTime(-9999))
  last_balance!(params["Recover"], kwargs)
  check_dictentry!(params["Recover"], "vacation", kwargs, Int, 0, :vacation_balance)
  check_dictentry!(params["Recover"], "sickdays", kwargs, Int, 0, :sickdays_balance)

  ## Datasets and sources
  # Ensure, Datasets section exists in params
  haskey(params, "Datasets") || (params["Datasets"] = dict())
  # Fill dict
  check_dictentry!(params["Datasets"], "dir", kwargs, String, ".")
  check_dictentry!(params["Datasets"], "kimai", kwargs, String, "export.csv")
  check_dictentry!(params["Datasets"], "vacation", kwargs, Union{Int,String}, 0)
  check_dictentry!(params["Datasets"], "sickdays", kwargs, Union{Int,String}, 0)
  # Check files and standardise dict entries
  params["Datasets"]["kimai"] = normfiles(params["Datasets"]["kimai"], params["Datasets"]["dir"], mandatory=true)
  params["Datasets"]["vacation"] isa Int ||
    (params["Datasets"]["vacation"] = normfiles(params["Datasets"]["vacation"], params["Datasets"]["dir"]))
  params["Datasets"]["sickdays"] isa Int ||
    (params["Datasets"]["sickdays"] = normfiles(params["Datasets"]["sickdays"], params["Datasets"]["dir"]))

  ## General settings
  # Ensure, Settings section exists in params
  haskey(params, "Settings") || (params["Settings"] = dict())
  # Fill dict
  check_dictentry!(params["Settings"], "state", kwargs, String, "SN")
  check_dictentry!(params["Settings"], "workload", kwargs, Real, 40)
  check_dictentry!(params["Settings"], "workdays", kwargs, Int, 5)
  check_dictentry!(params["Settings"], "vacation days", kwargs, Int, 30)
  check_dictentry!(params["Settings"], "vacation deadline", kwargs, Union{String, Date}, Date(0001, 03, 31))
  default = year(unix2datetime(mtime(params["Datasets"]["kimai"])))
  default == 1970 && (default = year(today()))
  check_dictentry!(params["Settings"], "finalyear", kwargs, Int, default)
  # Validate/update calendar entries
  params["tmp"] = dict{String,Any}(
    "calendar" => cal.DE(Symbol(params["Settings"]["state"]))
  )
  if params["Settings"]["vacation deadline"] < Date(0,12,31)
    params["Settings"]["vacation deadline"] = Date(0,12,31)
  end
  # Return revised session parameters
  return params
end


# Helper functions to validate input

"""
    check_dictentry!(collection::dict, entry::String, kwargs, type, default, kw::Symbol=Symbol(""))::Nothing

Check `entry` exists in `collection` and is of the specified `type` and not nothing,
otherwise add an entry to the `collection` from `kwargs`, if provided, or use `default`
value for missing data.

For `Date` values add the year. If the date is passed as String assume a date format
"dd.mm.yyyy".
"""
function check_dictentry!(collection::dict, entry::String, kwargs, type, default, kw::Symbol=Symbol(""))::Nothing

  # Define standard keyword symbol
  isempty(kw) && (kw = Symbol(join(split(entry), "_")))
  # Define fallback value from config file for non-dates
  collection[entry] = if haskey(collection, entry) && !isnothing(collection[entry]) #&& !(default isa Date)
    msg = "$entry has type $(typeof(collection[entry])), should have type $type; looking for kwarg or default"
    checktype(collection, entry, type, default, msg)
  end
  # Overwrite fallback with kwargs
  if haskey(kwargs, kw)
    # Overwrite fallback with kwarg
    collection[entry] = checktype(kwargs, kw, type, default)
  end
  collection[entry] = if default isa Date && collection[entry] isa String
    Date(collection[entry]*"0001", dateformat"d.m.y")
  elseif !haskey(collection, entry) || isnothing(collection[entry])
    # Last fallback: default
    default
  else
    collection[entry]
  end
  return # return nothing
end


"""
    function checktype(
      container,
      entry,
      type,
      default,
      msg::String="\$entry has type \$(typeof(container[entry])), should have type \$type; parameter ignored"
    )

Return the value of `entry` in `container` if of the specified `type`,
otherwise return the `default` and warn with a `msg`.
"""
function checktype(
  container,
  entry,
  type::Type,
  default,
  msg::String="$entry has type $(typeof(container[entry])), should have type $type; parameter ignored"
)
  if container[entry] isa type
    return container[entry]
  else
    @warn msg
    return default
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
    @warn "$file does not exist; 0 days used instead"
    file = ""
  end

  return file
end


# Helper function to recover balances from previous sessions

"""
    recover_session!(params, recover)::Nothing

Add an entry "Recover" to `params`. If `recover` is `false` or no previous session exists,
an empty dict is added to params, if recover is `true`, a dict with recovery data is added
to `params`. If several previous sessions are saved, the user can choose, which session to
recover or pass the session name as `Symbol` with `recover`.
"""
function recover_session!(params, recover)::Nothing
  # Get list of previous sessions
  sessions = filter(endswith(".yaml"), readdir(normpath(@__DIR__, "../sessions/"), join=true))
  # Add recovery data to params based on recover options
  if recover == false
    params["Recover"] = dict()
    return
  elseif recover == true && length(sessions) == 0

    @info "No previous sessions found. You can adjust last balances with kwargs balance, vacation_balance, and sickdays_balance."
    params["Recover"] = dict()
    return
  elseif recover == true && length(sessions) == 1
    @info "continue previous $(splitext(basename(sessions[1]))[1]) session"
    retrieve_session!(params, sessions[1])
  elseif recover == true
    session = select_session(sessions)
    retrieve_session!(params, session)
  else
    session = joinpath("../sessions/", string(recover, ".yaml"))
    if isfile(session)
      return retieve_session!(params, session)
    else
      @warn "previous session $recover not found"
      session = select_session(sessions)
      retrieve_session!(params, session)
    end
  end
  return
end


"""
    select_session(sessions)::String

List all available `sessions` and return the file name of the chosen session.
"""
function select_session(sessions)::String
  println()
  for (i, s) in enumerate(splitext.(basename.(sessions)))
    println(lpad(i, 3), " ... ", s[1])
  end
  print("\nChoose recovery session: ")
  i = parse(Int, readline())
  return sessions[i]
end


"""
    retrieve_session!(params, file)::Nothing

Retrieve recovery data from the given `file` and merge with `params`.
Existing `params` entries are overwritten by duplicate keys in the `file`.
"""
function retrieve_session!(params, file)::Nothing
  session = yml.load_file(file, dicttype=dict)
  merge!(params, session)
  return
end


"""
    last_balance!(data, kwargs)::Nothing

Check `data` has an entry `"balance"` of type `AbstractFloat` or `AbstractTime`
and construct dict entries `"hours"` with `balance` in hours as `AbstractFloat`
and `"time"` with `balance` as `CompoundPeriod`. Missing `data` entries are filled
with `0` `hours` or `empty period` `time`. A `:balance` entry in `kwargs` overwrites
entries in `data`.
"""
function last_balance!(data, kwargs)::Nothing
  if haskey(kwargs, :balance)
    # Check for kwargs first and set balance in hours or as period depending on input format
    if kwargs[:balance] isa Real
      data["balance"] =  htoms(kwargs[:balance])
    elseif kwargs[:balance] isa Dates.AbstractTime
      data["balance"] = Dates.toms(kwargs[:balance])
    else
      @warn "balance must be number of hours or a period; 0 hours used"
      data["balance"] = 0.0
    end
  elseif haskey(data, "balance")
    return # Internal logs are assumed correct
  else
    # Use 0 hours and empty period as default
    data["balance"] = 0.0
  end
  return
end
