#!/usr/bin/env julia

#Dependencies
using JuliaDB
using HTTP
using CodecZlib
using EzXML
using Gumbo
using Cascadia
using Dates

#Functions
function PareDownIO(MyIOSTREAM,WriteLocation) #Reduce Size of XML Files (keep RAM usage as small as possible)
LocF=open(WriteLocation, "w");
	for LocLine in eachline(MyIOSTREAM)
		if occursin("credit",LocLine) || occursin("id",LocLine) || occursin("model",LocLine) || occursin("host",LocLine) || occursin("coproc",LocLine) || occursin("xml",LocLine)
			write(LocF, string(LocLine,"\n"));
			#println(LocLine)
		end
	end
close(LocF)
end

function MyStreamXMLparse(XMLstream,OutFile) #Read XML files line by line and extract desired values (avoids memory leak from libXML2)
reader = open(EzXML.StreamReader, XMLstream)
	
	#Arrays to accumulate needed data
	LocHostID = [];
	LocTotCred = [];
	LocRAC = [];
	LocPModel = [];
	LocGModel = [];
	
	#Flags to indicate if all values where found for each host
	foundID=true
	foundTotCred=true
	foundRAC=true
	foundPModel=true
	foundGModel=true
	
	for line in reader
		if (reader.type==1) && (reader.name=="host") # If we find new host reset flags for new node
			if foundID==false
				push!(LocHostID,"0")
			end
			if foundTotCred==false
				push!(LocTotCred,"0")
			end
			if foundRAC==false
				push!(LocRAC,"0")
			end			
			if foundPModel==false
				push!(LocPModel,"NONE")
			end		
			if foundGModel==false
				push!(LocGModel,"NONE")
			end		
			foundID=false
			foundTotCred=false
			foundRAC=false
			foundPModel=false
			foundGModel=false		
		end
		#Locate which data type we found and save value
		if (reader.type==1) && (reader.name=="id") # Type=1 is an element/node
			push!(LocHostID,reader.content)
			foundID=true
		end
		if (reader.type==1) && (reader.name=="total_credit") # Type=1 is an element/node
			push!(LocTotCred,reader.content)
			foundTotCred=true
		end
		if (reader.type==1) && (reader.name=="expavg_credit") # Type=1 is an element/node
			push!(LocRAC,reader.content)
			foundRAC=true
		end
		if (reader.type==1) && (reader.name=="p_model") # Type=1 is an element/node
			push!(LocPModel,uppercase(string(reader.content)))
			foundPModel=true
		end
		if (reader.type==1) && (reader.name=="coprocs") # Type=1 is an element/node
			push!(LocGModel,uppercase(string(reader.content)))
			foundGModel=true
		end
	end
	#Final cleanup in case last host had missing data
	if foundID==false
		push!(LocHostID,"0")
	end
	if foundTotCred==false
		push!(LocTotCred,"0")
	end
	if foundRAC==false
		push!(LocRAC,"0")
	end			
	if foundPModel==false
		push!(LocPModel,"NONE")
	end		
	if foundGModel==false
		push!(LocGModel,"NONE")
	end		
	
	LocHostID=parse.([Int64],LocHostID)
	LocTotCred=parse.([Float64],LocTotCred)
	LocRAC=parse.([Float64],LocRAC)

	LocalTable=table(LocHostID,LocPModel,LocGModel,LocTotCred,LocRAC; names = [:ID, :CPUmodel, :GPUmodel, :TotCred, :RAC]);
	LocalTable=filter(host -> host.RAC > 1.0 , LocalTable)		#Remove any inactive hosts from database
	save(LocalTable,OutFile)
	

end


###
### Start Main run
###

# Check if we should use LowMemoryMode (for Rasbery PI and other linux based SBCs)
#		Reduces download speed slightly but drops memory usage to <1GB
FracOfAvailMemory = Sys.total_memory() / 1024^3 / 5.75;
UseLowMemoryMode = false
if Sys.islinux() && FracOfAvailMemory<1
	println("Low system RAM detected:\n     Switching to low memory mode")
	UseLowMemoryMode=true
end

WhiteListFile=joinpath(".","WhiteList.csv");# Import Gridcoin WhiteList from CSV file
println("Reading $WhiteListFile")
WhiteListTable=loadtable(WhiteListFile);
WLlength=size(select(WhiteListTable,1),1);


#Remove old host data
FullHostFilePath=joinpath(pwd(),"HostFiles");
if isdir(FullHostFilePath)
	if Sys.iswindows()
		run(`cmd /C rmdir /Q /S $FullHostFilePath`)	#Windows File Permisions issue (workaround)
	else
		rm("HostFiles"; force=true, recursive=true);
	end
end
mkdir("HostFiles")							#Make new folder to store host data

#Clean up any leftover data in temp directory
TempPath=joinpath(tempdir(),"QM_Temp")		#Save path to working temp directory 
if isdir(TempPath)
	if Sys.iswindows()
		run(`cmd /C rmdir /Q /S $TempPath`)			#Windows File Permisions issue (workaround)
	else
		rm(TempPath; force=true, recursive=true);
	end
end
mkdir(TempPath)


#Check with block explorer to verify greylist/TeamRAC
statsURL="https://www.gridcoinstats.eu/project";
statsHTML=joinpath(tempdir(),"QM_Temp","stats.html")

if Sys.iswindows()
	run(`cmd /C curl $statsURL -s -o $statsHTML`)
else
	run(`wget $statsURL -q -O $statsHTML`);
end

HTMLdat=Gumbo.parsehtml(read(statsHTML,String));
HTMLtab=eachmatch(Selector("tr"), HTMLdat.root);
TableLines=size(HTMLtab,1);
CurrentWLsize=TableLines-1;
WLTab_RACvect=[ Inf for ind=1:WLlength];
for lineNum = 2:TableLines 
	line=HTMLtab[lineNum];
	ProjName=string(line[1][1][1]);
	TeamRAC=parse(Int64,replace(string(line[7][1][1]),' ' => ""));
	locIndex=findall(x-> x==ProjName, select(WhiteListTable,:FullName));
	
	if ~isempty(locIndex)
		WLTab_RACvect[locIndex[1]]=TeamRAC;
	else
		#Print notice if QuickMag whitelist disagrees with block explorer
		#Einstein does not publish host data, so it is not listed in WhiteList.csv
		println("    Not building host database for: $ProjName")	
	end
	
end
rm(statsHTML);

WhiteListTable=JuliaDB.pushcol(WhiteListTable, :TeamRAC, WLTab_RACvect)
WhiteListTable=JuliaDB.pushcol(WhiteListTable, :NumWL_Proj, [CurrentWLsize for ind=1:WLlength]);
WhiteListTable=JuliaDB.pushcol(WhiteListTable, :TimeStamp, [Dates.now() for ind=1:WLlength]);
GreyList=findall(x-> x==Inf,select(WhiteListTable,:TeamRAC))	#Print notice if projects are on greylist
for line in GreyList
	println("    Project on greylist: $(WhiteListTable[line].FullName)")
end
println("")


println("Downloading Host Data")

FailedDownloads=[];


if UseLowMemoryMode	
	for ind=1:WLlength	#Process projects in WhiteList.csv (Runs in parallel if julia started with multiple threads) 
			row=WhiteListTable[ind];
			if (row.TeamRAC!=Inf)	
				println("    Starting to download project: $(row.Project), $(row.Type), $(row.URL)")
				
				LocFilePath=joinpath(".","HostFiles","$(row.Type)"*"_"*"$(row.Project).jldb") #Path to saved data
				LocTemp=joinpath(tempdir(),"QM_Temp","$(row.Type)"*"_"*"$(row.Project).xml") #Path to temp XML file
				
				try
					#Switching from LocFileStream/PareDownIO to run(bash -c "wget | catz | grep -E") can greatly reduce RAM usage (Linux only)
					locURL=row.URL
					run(`bash -c "./src/lowMemDownload.sh $locURL $LocTemp"`)

					
					MyStreamXMLparse(LocTemp,LocFilePath)	#Convert XML to binary JuliaDB file

					#Remove temp XML file
					if Sys.iswindows()
						#run(`cmd /C del $LocTemp`) #Windows File Permisions issue
					else
						rm(LocTemp);
					end				

					println("    Finished downloading project: $(row.Project)")
				catch e					#catch errors that occur if a project website is down
					println("Error: Unable to download data for $(row.Project)")
					push!(FailedDownloads,ind)
				end
			end
	end 
else
	Threads.@threads for ind=1:WLlength	#Process projects in WhiteList.csv (Runs in parallel if julia started with multiple threads) 
			row=WhiteListTable[ind];
			if (row.TeamRAC!=Inf)	
				println("    Starting to download project: $(row.Project), $(row.Type), $(row.URL)")
				
				LocFilePath=joinpath(".","HostFiles","$(row.Type)"*"_"*"$(row.Project).jldb") #Path to saved data
				LocTemp=joinpath(tempdir(),"QM_Temp","$(row.Type)"*"_"*"$(row.Project).xml") #Path to temp XML file
				
				try
					#Downloading using Julia tools results in higher download speeds
					LocFileStream = GzipDecompressorStream( IOBuffer(HTTP.get(row.URL).body)) #Download & Decompress xml
					PareDownIO( LocFileStream,LocTemp)	#Remove most unnecessary elements from XML to save RAM

					
					MyStreamXMLparse(LocTemp,LocFilePath)	#Convert XML to binary JuliaDB file

					#Remove temp XML file
					if Sys.iswindows()
						#run(`cmd /C del $LocTemp`) #Windows File Permisions issue
					else
						rm(LocTemp);
					end				

					println("    Finished downloading project: $(row.Project)")
				catch e					#catch errors that occur if a project website is down
					println("Error: Unable to download data for $(row.Project)")
					push!(FailedDownloads,ind)
				end
			end
	end 
end


# Finalize WhiteListTable.jldb noting missing data (Host data & Team data from block explorer)
TeamRacVect=select(WhiteListTable,:TeamRAC);
for jnd in FailedDownloads
	TeamRacVect[jnd] = Inf ;	
end
WhiteListTable=JuliaDB.popcol(WhiteListTable, :TeamRAC)
WhiteListTable=JuliaDB.pushcol(WhiteListTable, :TeamRAC, TeamRacVect)
save(WhiteListTable,joinpath(".","HostFiles","WhiteList.jldb")) #Save checked and parsed WhiteListTable for quicker access


#Clean up temp directory
if Sys.iswindows()
	#run(`cmd /C rmdir /Q /S $TempPath`) #Windows File Permisions issue
else
	rm(TempPath; force=true, recursive=true);
end
