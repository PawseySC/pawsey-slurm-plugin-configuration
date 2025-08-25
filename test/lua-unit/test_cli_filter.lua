--[[
    Unit tests for code in the Pawsey slurm lua cli_filter.

    The cli_filter provides three global functions as part of
    the slurm lua cli_filter API. It also uses a number of
    local functions in the implementation of these API functions.

    These unit tests aim to provide some test coverage of
    both the API functions and the local implementation functions,
    though at this point in time only tests for the latter have
    been implemented.
]]--

lunit = require('lunit')

-- Mock slurm interface:
--
-- Slurm itself exports some interfaces to slurm functionality
-- and key constants to the cli_filter lua program; mock these
-- for isolated unit testing directly in the global environment.

slurm_log_error_tbl = {}
slurm_log_debug_tbl = {}

slurm = {}
function slurm.log_error(fmt, ...)
    table.insert(slurm_log_error_tbl, string.format(fmt, ...))
end
function slurm.log_debug(fmt, ...)
    table.insert(slurm_log_debug_tbl, string.format(fmt, ...))
end
-- For now at least, cli_filter debug output is being sent via slurm.log_info.
function slurm.log_info(fmt, ...)
    table.insert(slurm_log_debug_tbl, string.format(fmt, ...))
end
-- If we use slurm.json_cli_options(options) in the filter, we'll need something
-- here too.
function slurm.json_cli_options(opts)
    return '{}'
end
slurm.SUCCESS = 0
slurm.ERROR = -1

-- Mock os.getenv with mock os table as required

mock_unset_tbl = {}
mock_setenv_tbl = {}

mock_os = {}
setmetatable(mock_os, { __index = os })
function mock_os.getenv(v)
    if mock_unset_tbl[v] then return nil
    elseif mock_setenv_tbl[v] ~= nil then return mock_setenv_tbl[v]
    else return os.getenv(v)
    end
end

function mock_setenv(v, x)
    mock_unset_tbl[v] = nil
    mock_setenv_tbl[v] = x
end

function mock_unset(v, x)
    mock_unset_tbl[v] = true
    mock_setenv_tbl[v] = nil
end

function mock_clearenv()
    mock_unset_tbl = {}
    mock_setenv_tbl = {}
end


-- Schlep in cli_filter; returns table of local functions to test.

clif_functions = dofile("../../stage/cli_filter.lua")

-- Test suite:

T = {}
function T.test_tokenize()
    local tokenize = clif_functions.tokenize
    local eq = lunit.test_eq_v

    -- simple tokens
    assert(eq({}, tokenize('', ' ')))
    assert(eq({'abc'}, tokenize('abc', ' ')))
    assert(eq({'abc', 'def', '', 'ghi'}, tokenize('abc def  ghi', ' ')))
    assert(eq({'', 'abc', 'def', '', 'ghi'}, tokenize(' abc def  ghi  ', ' ')))

    -- max_tokens -1 will pick up trailing empty tokens
    assert(eq({'', 'abc', 'def', '', 'ghi', '', ''}, tokenize('-abc-def--ghi--', '-', -1)))

    -- zero width separators
    assert(eq({}, tokenize('', '')))
    assert(eq({'a'}, tokenize('a', '')))
    assert(eq({'a', ''}, tokenize('a', '', -1)))
    assert(eq({'a', 'b', 'c'}, tokenize('abc', '')))
    assert(eq({'abc', ',def', ',ghi'}, tokenize('abc,def,ghi', '%f[,]')))

    -- other patterns
    assert(eq({'', 'abc', 'def', 'ghi'}, tokenize(' abc def  ghi  ', ' +')))
    assert(eq({'', 'a', 'b', 'c', 'd', 'e', 'f'}, tokenize(' abc def  ', ' *')))

    -- limit number of tokens
    assert(eq({'a', 'b', 'c=d'}, tokenize('a=b=c=d', '=', 3)))
end

function T.test_parse_csv_tbl()
    local parse_csv_tbl = clif_functions.parse_csv_tbl
    local eq = lunit.test_eq_v

    assert(eq({}, parse_csv_tbl('')))
    assert(eq({'abc'}, parse_csv_tbl('abc')))

    assert(eq({abc = '3'}, parse_csv_tbl('abc=3')))
    assert(eq({abc = '4'}, parse_csv_tbl('abc=4', '=')))
    assert(eq({abc = '5'}, parse_csv_tbl('abc:5', ':')))

    assert(eq({[1] = 'foo', [2] = 'bar', ['3'] = 'three', empty = '', fish = 'cake'},
        parse_csv_tbl('3=three,foo,bar,empty=,fish=cake')))

    -- check prefix snipping, too
    assert(eq({[1] = 'foo', [2] = 'bar', ['3'] = 'three', empty = '', fish = 'cake'},
        parse_csv_tbl('3=three,xyz/foo,bar,empty=,xyz/fish=cake', '=', 'xyz/')))
end

function T.test_collect_csv_tbl()
    local parse_csv_tbl = clif_functions.parse_csv_tbl
    local collect_csv_tbl = clif_functions.collect_csv_tbl
    local eq = lunit.test_eq_v

    -- for array-like tables, order should be preserved
    assert(eq('', collect_csv_tbl({})))
    assert(eq('foo,bar', collect_csv_tbl({'foo', 'bar'})))

    assert(eq('foo:3', collect_csv_tbl({ foo = 3 }, ':')))
    assert(eq('bar=x=y', collect_csv_tbl({ bar = 'x=y' }, '=')))

    -- order may be arbitrary, so check round-trip with parse_csv_tbl.

    local tbl_in = { foo = 4, 'quux', 'xyzzzy', bar = 'baz' }
    local tbl_check = { foo = '4', 'quux', 'xyzzzy', bar = 'baz' }
    assert(eq(tbl_check, parse_csv_tbl(collect_csv_tbl(tbl_in))))
    assert(eq(tbl_check, parse_csv_tbl(collect_csv_tbl(tbl_in, ':'), ':')))
    assert(eq(tbl_check, parse_csv_tbl(collect_csv_tbl(tbl_in, '='), '=')))

    -- and also check inserting prefixes

    tbl_check = { ['xyz/foo'] = '4', 'xyz/quux', 'xyz/xyzzzy', ['xyz/bar'] = 'baz' }
    assert(eq(tbl_check, parse_csv_tbl(collect_csv_tbl(tbl_in, ':', 'xyz/'), ':')))
    assert(eq(tbl_check, parse_csv_tbl(collect_csv_tbl(tbl_in, '=', 'xyz/'), '=')))

    assert(eq('', collect_csv_tbl({}, ':', 'pfx/')))
end

function T.test_collate_spank_options()
    local collate_spank_options = clif_functions.collate_spank_options
    local eq = lunit.test_eq_v

    local options = {}
    assert(eq({}, collate_spank_options(options)))

    options.spank = 3
    assert(eq({}, collate_spank_options(options)))

    options.spank = {}
    assert(eq({}, collate_spank_options(options)))

    options.spank = { foo = 37 }
    assert(eq({}, collate_spank_options(options)))

    options.spank = { a = { fish = 3, cake = 5}, b = { bean = 'foo' }, c = 'notatable' }
    assert(eq({ fish = 3, cake = 5, bean = 'foo' }, collate_spank_options(options)))
end

function T.test_convert_MiB()
    local convert_MiB = clif_functions.convert_MiB
    local eq = lunit.test_eq_v

    assert(eq(0, convert_MiB(0)));
    assert(eq(0, convert_MiB('0')));
    assert(eq(123, convert_MiB(123)));
    assert(eq(123, convert_MiB('123')));
    assert(eq(123.5, convert_MiB(123.5)));
    assert(eq(123.5, convert_MiB('123.5')));

    assert(eq(nil, convert_MiB('123x')));

    assert(eq(0.5, convert_MiB('512k')));
    assert(eq(0.5, convert_MiB('512K')));

    assert(eq(123.5, convert_MiB('123.5m')));
    assert(eq(123.5, convert_MiB('123.5M')));

    assert(eq(512, convert_MiB('0.5g')));
    assert(eq(512, convert_MiB('0.5G')));

    assert(eq(512, convert_MiB('0.5g')));
    assert(eq(512, convert_MiB('0.5G')));

    assert(eq(1179648, convert_MiB('1.125T')));
    assert(eq(1179648, convert_MiB('1.125T')));
end

local mock_show_partition_output_tbl = {
    work = "PartitionName=work AllowGroups=ALL AllowAccounts=ALL \z
            AllowQos=ALL AllocNodes=ALL Default=YES QoS=N/A \z
            DefaultTime=01:00:00 DisableRootJobs=NO ExclusiveUser=NO \z
            GraceTime=0 Hidden=NO MaxNodes=UNLIMITED MaxTime=1-00:00:00 \z
            MinNodes=0 LLN=NO MaxCPUsPerNode=UNLIMITED \z
            Nodes=nid[001008-001011,001020-001023] \z
            PriorityJobFactor=0 PriorityTier=0 RootOnly=NO ReqResv=NO \z
            OverSubscribe=FORCE:1 OverTimeLimit=NONE PreemptMode=OFF \z
            State=UP TotalCPUs=2048 TotalNodes=8 SelectTypeParameters=NONE \z
            JobDefaults=(null) DefMemPerCPU=920 MaxMemPerCPU=1840 \z
            TRES=cpu=2048,mem=1960000M,node=8,billing=2048 \z
            TRESBillingWeights=CPU=1",

    gpu =  "PartitionName=gpu AllowGroups=ALL AllowAccounts=ALL \z
            AllowQos=ALL AllocNodes=ALL Default=NO QoS=N/A \z
            DefaultTime=01:00:00 DisableRootJobs=NO ExclusiveUser=NO \z
            GraceTime=0 Hidden=NO MaxNodes=UNLIMITED MaxTime=1-00:00:00 \z
            MinNodes=0 LLN=NO MaxCPUsPerNode=UNLIMITED \z
            Nodes=nid[001000,001002,001004,001006] \z
            PriorityJobFactor=0 PriorityTier=0 RootOnly=NO ReqResv=NO \z
            OverSubscribe=NO OverTimeLimit=NONE PreemptMode=OFF \z
            State=UP TotalCPUs=512 TotalNodes=4 \z
            SelectTypeParameters=CR_SOCKET_MEMORY \z
            JobDefaults=DefMemPerGPU=29440 \z
            DefMemPerNode=UNLIMITED MaxMemPerNode=UNLIMITED \z
            TRES=cpu=512,mem=980000M,node=4,billing=2048,gres/gpu=32 \z
            TRESBillingWeights=CPU=1,gres/GPU=64"
}

local mock_show_node_gres_output_tbl = {
    work = '(null)',
    gpu  = 'gpu:8(S:0-7),tmp:3500G',
    foo  = 'tmp:2T'
}

-- provide a substitute for invoking `scontrol partition info`
local function mock_run_show_partition(partition)
    local out = ''
    if not partition or partition == '' then
        for _, entry in pairs(mock_show_partition_output_tbl) do
            out  = out  .. entry .. '\n'
        end
    else
        out = mock_show_partition_output_tbl[partition]
    end

    if out then return out, 0
    else return nil, 1
    end
end

-- provide a substitute for invoking `sinfo nodes -h -o %G -p`
local function mock_run_show_node_gres(partition)
    local out = ''
    if partition ~= '' then out = mock_show_node_gres_output_tbl[partition] end

    if out then return out, 0
    else return nil, 1
    end
end

function T.test_get_default_partition_or_env()
    local tmp = lunit.mock_function_upvalues(clif_functions.get_default_partition_or_env, { run_show_partition = mock_run_show_partition }, true)
    local get_default_partition_or_env = lunit.mock_function_env(tmp, { os = mock_os }, true)
    local eq = lunit.test_eq_v

    mock_unset('SLURM_JOB_PARTITION')
    assert(eq('work', get_default_partition_or_env()))

    mock_setenv('SLURM_JOB_PARTITION', 'caterpillar')
    assert(eq('caterpillar', get_default_partition_or_env()))

    mock_unset('SLURM_JOB_PARTITION')

    -- temporarily munge mock partition info to remove Default
    local saved = mock_show_partition_output_tbl.work;
    mock_show_partition_output_tbl.work = string.gsub(saved, 'Default=[^%s]*', '')

    local result = get_default_partition_or_env()
    mock_show_partition_output_tbl.work = saved

    assert(eq(nil, result))
end

function T.test_get_partition_info()
    local get_partition_info = lunit.mock_function_upvalues(clif_functions.get_partition_info, { run_show_partition = mock_run_show_partition }, true)
    local eq = lunit.test_eq_v

    local pinfo_work = get_partition_info('work')
    local pinfo_gpu = get_partition_info('gpu')

    assert(eq('4', pinfo_gpu.TotalNodes))
    assert(eq('8', pinfo_work.TotalNodes))

    assert(eq({ DefMemPerGPU = '29440' }, pinfo_gpu.JobDefaults))
    assert(eq({}, pinfo_work.JobDefaults))

    assert(eq({ cpu = '512', mem = '980000M', node = '4', billing = '2048', ['gres/gpu'] = '32' }, pinfo_gpu.TRES))
    assert(eq({ cpu = '2048', mem = '1960000M', node = '8', billing = '2048' }, pinfo_work.TRES))

    assert(eq({ CPU = '1', ['gres/GPU'] = '64' }, pinfo_gpu.TRESBillingWeights))
    assert(eq({ CPU = '1' }, pinfo_work.TRESBillingWeights))
end

function T.test_get_node_gres()
    local get_node_gres = lunit.mock_function_upvalues(clif_functions.get_node_gres, { run_show_node_gres = mock_run_show_node_gres }, true)
    local eq = lunit.test_eq_v

    local ngres_work = get_node_gres('work')
    local ngres_gpu = get_node_gres('gpu')
    local ngres_foo = get_node_gres('foo')

    assert(eq({}, ngres_work))

    assert(eq(nil, ngres_work.gpu))
    assert(eq('8(S:0-7)', ngres_gpu.gpu))
    assert(eq(nil, ngres_foo.gpu))

    assert(eq(nil, ngres_work.tmp))
    assert(eq('3500G', ngres_gpu.tmp))
    assert(eq('2T', ngres_foo.tmp))
end

function T.test_slurm_error()
    local slurm_error = clif_functions.slurm_error
    local slurm_errorf = clif_functions.slurm_errorf
    local eq = lunit.test_eq_v

    slurm_log_error_tbl = {}

    assert(eq(slurm.ERROR, slurm_error('not a %s fmt')))
    assert(eq('cli_filter: not a %s fmt', slurm_log_error_tbl[1]))

    assert(eq(slurm.ERROR, slurm_errorf('%s=%02d', 'foo', 3)))
    assert(eq('cli_filter: foo=03', slurm_log_error_tbl[2]))
end

function T.test_slurm_debug()
    local enable_debug = true
    local function mock_debug_lvl() return enable_debug and 1 or 0 end

    local slurm_debug = lunit.mock_function_upvalues(clif_functions.slurm_debug, { debug_lvl = mock_debug_lvl }, true)
    local slurm_debugf = lunit.mock_function_upvalues(clif_functions.slurm_debugf, { debug_lvl = mock_debug_lvl }, true)
    local eq = lunit.test_eq_v

    slurm_log_debug_tbl = {}

    slurm_debug('not a %s fmt')
    assert(eq('cli_filter: not a %s fmt', slurm_log_debug_tbl[1]))

    slurm_debugf('%s=%02d', 'foo', 3)
    assert(eq('cli_filter: foo=03', slurm_log_debug_tbl[2]))

    slurm_log_debug_tbl = {}
    enable_debug = false

    slurm_debug('not a %s fmt')
    slurm_debugf('%s=%02d', 'foo', 3)
    assert(eq(0, #slurm_log_debug_tbl))
end

function T.test_cli_sets_memory()
    -- matches or is derived from mock partition info above
    local def_mem_per_cpu = 920
    local n_threads_per_node = 256

    local slurm_cli_pre_submit = lunit.mock_function_upvalues(slurm_cli_pre_submit,
         { run_show_partition = mock_run_show_partition, run_show_node_gres = mock_run_show_node_gres }, true)
    local eq = lunit.test_eq_v

    -- expect only mem-per-cpu to be set out of the memory options
    options = { partition = 'work', ['threads-per-core'] = 1 }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem']))
    assert(eq(def_mem_per_cpu*2, tonumber(options['mem-per-cpu'])))

    options = { partition = 'work', ['threads-per-core'] = 2 }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem']))
    assert(eq(def_mem_per_cpu, tonumber(options['mem-per-cpu'])))

    -- expect only mem to be set
    options = { partition = 'work', ['threads-per-core'] = 1, exclusive = 'exclusive' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(def_mem_per_cpu*n_threads_per_node, options['mem']))

    options = { partition = 'work', ['threads-per-core'] = 1, mem = '0?' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(def_mem_per_cpu*n_threads_per_node, options['mem']))

    options = { partition = 'work', ['threads-per-core'] = 2, exclusive = 'exclusive' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(def_mem_per_cpu*n_threads_per_node, options['mem']))

    options = { partition = 'work', ['threads-per-core'] = 2, mem = '0?' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(def_mem_per_cpu*n_threads_per_node, options['mem']))

    -- expect no other memory options to be set
    options = { partition = 'work', mem = '500M' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq('500M', options['mem']))

    options = { partition = 'work', ['threads-per-core'] = 1, ['mem-per-cpu'] = '500M' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq('500M', options['mem-per-cpu']))
    assert(eq(nil, options['mem']))

    -- if partition is gpu, also expect no memory mangling
    options = { partition = 'gpu', gpus = '1'}
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(nil, options['mem']))

    options = { partition = 'gpu', exclusive = 'exclusive' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['mem-per-gpu']))
    assert(eq(nil, options['mem-per-cpu']))
    assert(eq(nil, options['mem']))

    -- if partition is gpu, expect an error if memory request
    options = { partition = 'gpu', gpus = '1', mem = '500M'}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    options = { partition = 'gpu', gpus = '1', ['mem-per-gpu'] = '500M'}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    options = { partition = 'gpu', gpus = '1', ['mem-per-cpu'] = '500M'}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    options = { partition = 'gpu', exclusive = 'exclusive', mem = '500M'}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))
end

function T.test_cli_srun_requires_gpu()
    local tmp = lunit.mock_function_upvalues(slurm_cli_pre_submit,
         { run_show_partition = mock_run_show_partition, run_show_node_gres = mock_run_show_node_gres }, true)
    local slurm_cli_pre_submit = lunit.mock_function_env(tmp, { os = mock_os }, true)
    local eq = lunit.test_eq_v

    -- For srun outside an allocation, we allow there not to be an explicit gpu
    -- request option because `--gres=gpu:N` is not propagated to srun and we
    -- wish to permit a simple remote interactive shell case without requiring
    -- an explicit srun. Otherwise, without an existing allocation, we demand
    -- the srun requests gpu resources.

    mock_unset('SLURM_JOB_PARTITION')
    options = { type = 'srun', partition = 'gpu', gpus = '2' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu', gres = 'gres/gpu:2' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu', gres = 'gres/tmp:100G,gres/gpu:2' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu', gres = 'gres/tmp:100G' }
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu', gres = 'gres/gpu:0' }
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu', ['gpus-per-node'] = '2' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu', ['gpus-per-task'] = '2' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu' }
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    mock_setenv('SLURM_JOB_PARTITION', 'gpu')
    options = { type = 'srun', gpus = '2' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', gres = 'gres/gpu:2' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', ['gpus-per-node'] = '2' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', ['gpus-per-task'] = '2' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    mock_unset('SLURM_JOB_PARTITION')
end

function T.test_cli_tmp_requests()
    local slurm_cli_pre_submit = lunit.mock_function_upvalues(slurm_cli_pre_submit,
         { run_show_partition = mock_run_show_partition, run_show_node_gres = mock_run_show_node_gres }, true)
    local convert_MiB = clif_functions.convert_MiB
    local parse_csv_tbl = clif_functions.parse_csv_tbl
    local eq = lunit.test_eq_v

    -- NVMe tmp allocation limits are hard-coded; see cli_filter.lua:
    -- Max allocatable is 3500 GiB.
    -- Max non-exclusive is 3500 - 7*128 = 2604 GiB.
    local max_allocatable_tmp = convert_MiB('3500G')

    options = { partition = 'gpu', gres = 'gres/tmp:2600G,gres/gpu:2' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { partition = 'gpu', gres = 'gres/tmp:2700G,gres/gpu:2' }
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    -- Exclusive allocations always get the max tmp allocation.
    options = { partition = 'gpu', exclusive = 'exclusive', gres = 'gres/tmp:2700G,gres/gpu:2' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    local gres_options = parse_csv_tbl(options['gres'], ':', 'gres/')
    assert(eq(max_allocatable_tmp, convert_MiB(gres_options.tmp)))
end

function T.test_cli_srun_exclusive_gres()
    local tmp = lunit.mock_function_upvalues(slurm_cli_pre_submit,
         { run_show_partition = mock_run_show_partition, run_show_node_gres = mock_run_show_node_gres }, true)
    local slurm_cli_pre_submit = lunit.mock_function_env(tmp, { os = mock_os }, true)
    local convert_MiB = clif_functions.convert_MiB
    local parse_csv_tbl = clif_functions.parse_csv_tbl
    local eq = lunit.test_eq_v

    local max_allocatable_tmp = convert_MiB('3500G')
    local gpus_per_node = 8

    mock_unset('SLURM_JOB_PARTITION')

    -- Just salloc/sbatch:
    options = { partition = 'gpu', exclusive = 'exclusive' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    local gres_options = parse_csv_tbl(options['gres'], ':', 'gres/')
    assert(eq(max_allocatable_tmp, convert_MiB(gres_options.tmp)))
    assert(eq(gpus_per_node, tonumber(gres_options.gpu)))

   -- Srun outside allocation:
    options = { type = 'srun', partition = 'gpu', exclusive = 'exclusive' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    gres_options = parse_csv_tbl(options['gres'], ':', 'gres/')
    assert(eq(max_allocatable_tmp, convert_MiB(gres_options.tmp)))
    assert(eq(gpus_per_node, tonumber(gres_options.gpu)))

    -- Srun inside allocation: we should not be setting gres at all if not supplied.
    mock_setenv('SLURM_JOB_PARTITION', 'gpu')
    options = { type = 'srun', partition = 'gpu', exclusive = 'exclusive' }
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    assert(eq(nil, options['gres']))

    mock_unset('SLURM_JOB_PARTITION')
end

function T.test_cli_gpu_power_options_filter()
    local tmp = lunit.mock_function_upvalues(slurm_cli_pre_submit,
         { run_show_partition = mock_run_show_partition, run_show_node_gres = mock_run_show_node_gres }, true)
    local slurm_cli_pre_submit = lunit.mock_function_env(tmp, { os = mock_os }, true)
    local eq = lunit.test_eq_v

    -- Options --gpu-srange and --gpu-power-cap, presented via the spank options table in options.spank.lua, are
    -- only permitted on a gpu partition, with exclusive, and for salloc/sbatch or srun run outside of an allocation.

    mock_unset('SLURM_JOB_PARTITION')

    -- Missing --exclusive => fail:
    options = { partition = 'gpu', spank = { lua = { ['gpu-srange'] = '800-900' }}}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    options = { partition = 'gpu', spank = { lua = { ['gpu-power-cap'] = '400' }}}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu', spank = { lua = { ['gpu-srange'] = '800-900' }}}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu', spank = { lua = { ['gpu-power-cap'] = '400' }}}
    assert(eq(slurm.ERROR, slurm_cli_pre_submit(options, 0)))

    -- With exclusive is permitted:
    options = { partition = 'gpu', exclusive = 'exclusive', spank = { lua = { ['gpu-srange'] = '800-900' }}}
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { partition = 'gpu', exclusive = 'exclusive', spank = { lua = { ['gpu-power-cap'] = '400' }}}
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', exclusive = 'exclusive', partition = 'gpu', spank = { lua = { ['gpu-srange'] = '800-900' }}}
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', exclusive = 'exclusive', partition = 'gpu', spank = { lua = { ['gpu-power-cap'] = '400' }}}
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    -- Srun within allocation cases should all succeed (spank plugin options are not reset for these srun invocations):
    mock_setenv('SLURM_JOB_PARTITION', 'gpu')
    options = { type = 'srun', partition = 'gpu', spank = { lua = { ['gpu-srange'] = '800-900' }}}
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu', spank = { lua = { ['gpu-power-cap'] = '400' }}}
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu', exclusive = 'exclusive', spank = { lua = { ['gpu-srange'] = '800-900' }}}
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))

    options = { type = 'srun', partition = 'gpu', exclusive = 'exclusive', spank = { lua = { ['gpu-power-cap'] = '400' }}}
    assert(eq(slurm.SUCCESS, slurm_cli_pre_submit(options, 0)))
    mock_unset('SLURM_JOB_PARTITION')
end

if not lunit.run_tests(T) then os.exit(1) end
