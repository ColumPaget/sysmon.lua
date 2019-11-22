
require("terminal")
require("strutil")
require("filesys")
require("stream")
require("process")
require("time")
require("sys")

function ReadFile(path)
local str=""
local S

S=stream.STREAM(path, "r")
if S ~= nil
then
	str=S:readdoc()
	S:close()
end

return strutil.stripTrailingWhitespace(str)
end


function DrawBar(wide, curr, max)
local val

val=curr / max

str=strutil.padto("", "*", val * wide)
str=strutil.padto(str, " ", wide)

return "["..str.."]"
end



function LoadCoreUsage(cpus)
local key, str
local S, toks, item
local total, idle, count

S=stream.STREAM("/proc/stat", "r")
if S ~= nil
then
	str=S:readln()
	while str ~= nil
	do
		toks=strutil.TOKENIZER(str, " ")
		key=toks:next()
		if string.match(key, "^cpu[0-9]") ~= nil
		then
			total=0
			count=0
			item=toks:next()
			while item ~= nil
			do
			total=total + tonumber(item)
			if count==3 then idle=tonumber(item) end
			count=count+1
			item=toks:next()
			end

			if cpus[key] ~= nil
			then
				cpus[key].used=total-idle
				cpus[key].total=total
			end
		end
		str=S:readln()
	end
	S:close()
else
print("FAIL TO OPEN /proc/stat")
end

end




function LoadCoreTemps(cpus, path)
local temps, item, id, str

temps=filesys.GLOB(path .. "/temp*input")
item=temps:first()
while item ~= nil
do
	str=ReadFile(string.gsub(item, "input$","label"))

	if string.sub(str, 1,5)=="Core "
	then
		id="cpu"..string.sub(str, 6)
		id=strutil.stripTrailingWhitespace(id)

		str=ReadFile(item)
		if str ~= nil then cpus[id].temp_curr=tonumber(str) / 1000 end

		str=string.gsub(item, "input$","max")
		str=ReadFile(str)
		if str ~= nil then cpus[id].temp_max=tonumber(str) / 1000 end

		str=string.gsub(item, "input$","crit")
		str=ReadFile(str)
		if str ~= nil then cpus[id].temp_crit=tonumber(str) / 1000 end

	end
	item=temps:next()
end
				
end


function LoadHardwareMon(path, name)	
end

function LoadHardwareMonitors(sys_info)
local monitors, item, str

monitors=filesys.GLOB("/sys/class/hwmon/*")
item=monitors:first()
while item ~= nil
do
	str=ReadFile(item.."/name")
	if str == "coretemp"
	then
		LoadCoreTemps(sys_info.cpus, item)
	else 
		LoadHardwareMon(str, item)	
	end
	item=monitors:next()
end
	
end


function LoadCpuInfo(cpus, path)
local name

name=filesys.basename(path)
if cpus[name] == nil
then
cpus[name]={}
cpus[name].name=name
cpus[name].used=0
cpus[name].total=0
cpus[name].last_used=0
cpus[name].last_total=0
end


if filesys.exists(path.."/cpufreq/scaling_driver") == true
then
	cpus[name].freq_driver=ReadFile(path.."/cpufreq/scaling_driver")
	cpus[name].freq_governor=ReadFile(path.."/cpufreq/scaling_governor")
	
	--freq is in kHz
	cpus[name].freq_min=tonumber(ReadFile(path.."/cpufreq/scaling_min_freq")) * 1000
	cpus[name].freq_max=tonumber(ReadFile(path.."/cpufreq/scaling_max_freq")) * 1000
	cpus[name].freq_curr=tonumber(ReadFile(path.."/cpufreq/scaling_cur_freq")) * 1000
end

end



function LoadCpus(cpus)
local cpu_dirs, item, cpu

cpu_dirs=filesys.GLOB("/sys/devices/system/cpu/cpu[0-9]*")
item=cpu_dirs:first()
while item ~=nil
do
LoadCpuInfo(cpus, item)
item=cpu_dirs:next()
end

LoadCoreUsage(cpus)

return cpus
end


function CpuSortCompare(i1, i2)
return tonumber( string.sub(i1.name, 4) ) < tonumber(string.sub(i2.name , 4))
end


function CpuCalcUsage(cpu)
local perc

perc=(cpu.used - cpu.last_used)*100 / (cpu.total - cpu.last_total)

cpu.last_used=cpu.used
cpu.last_total=cpu.total

return perc
end

--this function only called at startup
function LoadCpuDetails(cpus)
local S, str, toks, key, value
local id=""

S=stream.STREAM("/proc/cpuinfo", "r")
if S ~= nil
then
	str=S:readln()
	while str ~= nil
	do
	str=strutil.stripTrailingWhitespace(str)
	toks=strutil.TOKENIZER(str, ":")
	key=strutil.stripTrailingWhitespace(toks:next())
	value=strutil.stripLeadingWhitespace(toks:next())

	if key == "processor" then id="cpu"..value end

	if cpus[id] ~= nil
	then
	if key == "model name" 
	then 
	cpus[id].model=value
	if cpus[id].freq_max == nil then cpus[id].freq_max=strutil.fromMetric(string.match(value, "@(.*)Hz")) end
	end

	if key == "flags" then cpus[id].cpuflags=value end
	if key == "cache size" then cpus[id].cache=value end
	if key == "cpu MHz" and cpus[id].freq_curr==nil then cpus[id].freq_curr=tonumber(value) * 1000 * 1000 end
	end
	
	str=S:readln()
	end
	S:close()
end

end


function DrawCpus(cpus)
local count=0, i, cpu, str, gov, percent
local sorted={}

for i,cpu in pairs(cpus)
do
table.insert(sorted, cpu)
end

table.sort(sorted, CpuSortCompare)

for i,cpu in pairs(sorted)
do

	if strutil.strlen(cpu.freq_governor)==0 then gov="       " 
	elseif cpu.freq_governor=="userspace" then gov="locked "
	elseif cpu.freq_governor=="ondemand" then gov="demand "
	elseif cpu.freq_governor=="conservative" then gov="consv  "
	elseif cpu.freq_governor=="powersave" then gov="psave  "
	elseif cpu.freq_governor=="performance" then gov="perform"
	else gov=cpu.freq_governor
	end

	percent=CpuCalcUsage(cpu)
	str=string.format("% 5s %5.1f%% %s % 8sHz %s", cpu.name, percent, DrawBar(10, percent, 100), strutil.toMetric(tonumber(cpu.freq_curr), 2), gov)

	if cpu.temp_curr ~= nil
	then
		str=str..string.format("	% 3.1fc %s crit:%3.1fc", cpu.temp_curr, DrawBar(10, cpu.temp_curr, cpu.temp_max), cpu.temp_crit)
	end

	str=str .. "~>\n"

	Out:puts(str)
	count=count+1
end

end


function FilesystemsIgnored(fs_path)
local ignored={"/proc", "/dev", "/sys"}
local i, ign_fs, str

-- ignore any kind of blank string
if strutil.strlen(fs_path) < 1 then return true end

for i,ign_fs in ipairs(ignored)
do
	--if it straight-up matches, then it's ignored
	if fs_path== ign_fs then return true end

	--if the first part of it matches, then again it's ignored
	str=ign_fs.."/"
	if string.sub(fs_path, 1, strutil.strlen(str)) == str then return true end
end

return false
end

function LoadFilesystemUsage(filesystems)
local S, line, str, item, toks, fs 

S=stream.STREAM("/proc/self/mounts", "r")
if S ~= nil
then
	line=S:readln()
	while line ~= nil
	do
		toks=strutil.TOKENIZER(line, " ")
		toks:next()
		str=toks:next()

		if FilesystemsIgnored(str) ~= true
		then
			if filesystems[str] == nil then filesystems[str]={} end
			filesystems[str].name=str
			filesystems[str].used=filesys.fs_used(str)
			filesystems[str].size=filesys.fs_size(str)
		end

		line=S:readln()
	end
	S:close()
end

end


function DrawFilesystems(filesystems)
local i, fs, perc

	for i,fs in pairs(filesystems)
	do
		perc=fs.used * 100 / fs.size
		Out:puts(string.format("%-10s % 6.2f%%  %s  % 7s / %- 7s~>\n", fs.name, perc, DrawBar(10, fs.used, fs.size), strutil.toMetric(fs.used, 2), strutil.toMetric(fs.size, 2) ))
	end
end



function LoadMemUsage(mem)
local key, str
local S, toks

S=stream.STREAM("/proc/meminfo", "r")
if S ~= nil
then
	str=S:readln()
	while str ~= nil
	do
		str=strutil.stripTrailingWhitespace(str)
		toks=strutil.TOKENIZER(str, ":")
		key=toks:next()
		str=strutil.stripLeadingWhitespace(toks:remaining())
		toks=strutil.TOKENIZER(str, "\\S")
		str=toks:next()
		if key=="MemAvailable" then mem.avail=tonumber(str) * 1024 end
		if key=="MemTotal" then mem.total=tonumber(str) * 1024 end
		str=S:readln()
	end

mem.used=mem.total - mem.avail

S:close()
end
	
end


function DrawMem(mem)
local perc

perc=mem.used * 100 / mem.total

Out:puts( string.format("% 5s %s/%s  %5.1f%% %s ~>\n", "mem", strutil.toMetric(mem.used, 2), strutil.toMetric(mem.total, 2), perc, DrawBar(20, mem.used, mem.total)) )

end



function LoadNetUsage(nets)
local key, str, toks, bytes, pkts, trash

S=stream.STREAM("/proc/net/dev", "r")
if S ~= nil
then
	str=S:readln() --strip title line
	str=S:readln() --and again, title is two lines long!

	-- iface bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed


	str=S:readln()
	while str ~= nil
	do
		str=strutil.stripLeadingWhitespace(str)
		str=string.gsub(str, "%s+", " ")

		toks=strutil.TOKENIZER(str, ":| ", "m")
		key=toks:next()

		if nets[key] == nil then nets[key]={} end
		net=nets[key]

		trash=toks:next()
		net.bytes_in=toks:next()
		net.pkts_in=toks:next()
		net.errs_in=toks:next()
		net.drop_in=toks:next()
		trash=toks:next()
		trash=toks:next()
		trash=toks:next()
		trash=toks:next()
		net.bytes_out=toks:next()
		net.pkts_out=toks:next()
		net.errs_out=toks:next()
		net.drop_out=toks:next()

		str=S:readln()
	end
	S:close()
else
print("FAIL TO OPEN /proc/net/dev")
end

end


function DrawNetItem(tag, in_count, out_count)
local str

str=tag..":"
if in_count > 0 
then 
	str=str..string.format("~e%6s~0", strutil.toMetric(in_count, 2))
else
	str=str..string.format("%6s", strutil.toMetric(in_count, 2))
end

str=str.." i/o "

if out_count > 0 
then 
	str=str..string.format("~e%6s~0", strutil.toMetric(out_count, 2))
else
	str=str..string.format("%6s", strutil.toMetric(out_count, 2))
end

return str
end



function DrawNets(nets, nets_prev)
local str, key, net, prev

for key,net in pairs(nets)
do
	if nets_prev ~= nil then prev=nets_prev[key] end

	if prev ~= nil
	then
	str=string.format("% 5s  %s   %s  %s ~>", key, DrawNetItem("use", net.bytes_in - prev.bytes_in, net.bytes_out - prev.bytes_out), DrawNetItem("errs", tonumber(net.errs_in), tonumber(net.errs_out)), DrawNetItem("drop", tonumber(net.drop_in), tonumber(net.drop_out)))
	Out:puts(str.."\n")
	end
end

end


function LoadDMIDetails(sys_info)
sys_info.product_name=ReadFile("/sys/class/dmi/id/product_name")

if sys_info.bios == nil then sys_info.bios={} end
sys_info.bios.vendor=ReadFile("/sys/class/dmi/id/bios_vendor")
sys_info.bios.version=ReadFile("/sys/class/dmi/id/bios_version")
sys_info.bios.date=ReadFile("/sys/class/dmi/id/bios_date")

if sys_info.motherboard == nil then sys_info.motherboard={} end
sys_info.motherboard.vendor=ReadFile("/sys/class/dmi/id/board_vendor")
sys_info.motherboard.name=ReadFile("/sys/class/dmi/id/board_name")
sys_info.motherboard.tag=ReadFile("/sys/class/dmi/id/board_asset_tag")
sys_info.motherboard.version=ReadFile("/sys/class/dmi/id/board_version")

end


-- loads sys_infotem static information at startup
function LoadSysInfo(sys_info)

LoadCpus(sys_info.cpus)
LoadCpuDetails(sys_info.cpus)
LoadDMIDetails(sys_info)
end

function DrawSysInfo(sys_info)
local name, cpu, count, str
local cpu_models={}

if sys_info.product_name ~= nil
then
Out:puts("SYS:  " .. sys.hostname() .. " '" .. sys_info.product_name.."' up: " .. time.format("%d days + %H:%M:%S", sys.uptime()) .. "\n")
end

Out:puts("BIOS: " .. sys_info.bios.vendor .. " " .. sys_info.bios.version .. " " .. sys_info.bios.date .."\n")

str="MOBO: " .. sys_info.motherboard.vendor .. " " .. sys_info.motherboard.name
if strutil.strlen(sys_info.motherboard.tag) > 0 then str=str .. " asset-tag=".. sys_info.motherboard.tag end

Out:puts(str.."\n")


for name,cpu in pairs(sys_info.cpus)
do
	if cpu.model ~= nil
	then
	if cpu_models[cpu.model] == nil
	then
		cpu_models[cpu.model] = 1
	else
		cpu_models[cpu.model] = cpu_models[cpu.model] + 1
	end
	end
end

for name,count in pairs(cpu_models)
do
	Out:puts(string.format("%d * %s\n", count, name))
end

end


sys_info={}
sys_info.cpus={}
sys_info.mem={}
sys_info.filesystems={}
sys_info.nets=nil
sys_info.mem.avail=0
sys_info.mem.total=0

Out=terminal.TERM()
Out:clear()
LoadSysInfo(sys_info)

while 1 == 1
do
	Out:move(0,0)
	LoadCpus(sys_info.cpus)
	LoadHardwareMonitors(sys_info)
	LoadMemUsage(sys_info.mem)
	LoadFilesystemUsage(sys_info.filesystems)
	sys_info.nets_prev=sys_info.nets
	sys_info.nets={}
	LoadNetUsage(sys_info.nets)

	DrawSysInfo(sys_info)
	Out:puts("\n")

	DrawCpus(sys_info.cpus)
	Out:puts("\n")

	DrawMem(sys_info.mem)
	Out:puts("\n")

	DrawFilesystems(sys_info.filesystems)
	Out:puts("\n")

	DrawNets(sys_info.nets, sys_info.nets_prev)
	Out:flush()

	process.sleep(1)
end
Out:reset()
