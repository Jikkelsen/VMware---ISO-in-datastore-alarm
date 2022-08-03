#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
<#

 __      ____  __                            _____  _____  ____    _             _       _            _                         _                      
 \ \    / /  \/  |                          |_   _|/ ____|/ __ \  (_)           | |     | |          | |                       | |                     
  \ \  / /| \  / |_      ____ _ _ __ ___      | | | (___ | |  | |  _ _ __     __| | __ _| |_ __ _ ___| |_ ___  _ __ ___    __ _| | __ _ _ __ _ __ ___  
   \ \/ / | |\/| \ \ /\ / / _` | '__/ _ \     | |  \___ \| |  | | | | '_ \   / _` |/ _` | __/ _` / __| __/ _ \| '__/ _ \  / _` | |/ _` | '__| '_ ` _ \ 
    \  /  | |  | |\ V  V / (_| | | |  __/  _ _| |_ ____) | |__| | | | | | | | (_| | (_| | || (_| \__ \ || (_) | | |  __/ | (_| | | (_| | |  | | | | | |
     \/   |_|  |_| \_/\_/ \__,_|_|  \___| (_)_____|_____/ \____/  |_|_| |_|  \__,_|\__,_|\__\__,_|___/\__\___/|_|  \___|  \__,_|_|\__,_|_|  |_| |_| |_|
                                                                                                                                                       
                                                                                                                                                       
#>
#------------------------------------------------| HELP |------------------------------------------------#
<#
    .Synopsis
        This script will iterate over all datastores in the VMware environment, and report if there is .iso files. 
    .PARAMETER vCenterCredential
        Creds to import for authorization on vCenters
    .PARAMETER vCenter
        String of what vCenter to connect to
#>
#---------------------------------------------| PARAMETERS |---------------------------------------------#
# Set parameters for the script here
param
(
    [Parameter(Mandatory = $true)]
    [pscredential]
    $vCenterCredential,

    [Parameter(Mandatory = $true)]
    [String]
    $vCenter
)
#------------------------------------------------| SETUP |-----------------------------------------------#
# Manually set TLS version
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# Establishing connection to selected vCenter
# The connection is put in a variable, so it can be passed into each runspace.
Write-Host "Connecting to vCenters"
$Connection = Connect-VIServer -Server $vCenter -Credential $vCenterCredential

#--------------------------------------------| PROGRAM LOGIC |-------------------------------------------#

Write-Host "Getting Datastores"
# Get all desired datastores
#   Log is currently corrupted, and cannot be removed. Ignore it
#   Template datastores is supposed to contain .iso files, so they will also be disregared
$AllDatastores = get-datastore -server $Connection | Where-Object {$_.name -ne "log" -and $_.name -notmatch "-Templates"}

# TotalCount is needed to calculate the percentage status of completion
$TotalCount    = $AllDatastores.Count

Write-Host "Building queue"
# Build the Queue object, populate it with data store amount, and synchronize it
$queue             = [System.Collections.Queue]::new()
1..$TotalCount     | ForEach-Object { $queue.Enqueue($_) }
$SynchronizedQueue = [System.Collections.Queue]::synchronized($queue)


# Create new spec to initiate search. Specs is an advanced method to manipulate date
# The spec is created, then populated with paramaters, and then run
Write-Host "Creating Spec"
$Spec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
    
# Include everything .iso in the search
$Spec.MatchPattern = '*.iso'
    
# Include in the search file owner, size and type and create the query
# The search is first run within the loop below
$Spec.Details = New-Object VMware.Vim.FileQueryFlags  
$Spec.Details.FileOwner = $true
$Spec.Details.FileSize  = $true
$Spec.Details.FileType  = $true
$Spec.Query += New-Object VMware.Vim.IsoImageFileQuery

# Create a generic list to store all results from the loop
$List  = [System.Collections.Generic.List[String]]::new()

# Loop over all datastores in parallell, and store the result from each run in the list
# When starting the threads as jobs this console will immediately be available again, 
# since it needs not to wait for the completion of jobs in the background
$Job = $AllDatastores | ForEach-Object -AsJob -throttlelimit 11 -Parallel {
    
    # We are not interested in .iso files in datastores marked for deletion, or where they are unavailable
    if (($_.ParentFolder -eq "Delete") -or ($_.state -eq "unavailable")) { continue }

    # Import the SynchronizedQueue objet into the runspace of the script
    $sqCopy = $Using:SynchronizedQueue

    # Get datastore browser as view. 
    # The -server flag is needed, because parallelization spawns a new runspace.
    $browser = Get-View -Id $_.ExtensionData.Browser -Server $using:Connection
        
    # Initiate search
    $Result = $browser.SearchDatastoreSubFolders("[$($_.Name)]",$using:Spec)
    
    # There will always be a result, but the .file property will only be populated when an .iso is found
    if($Result.File)
    {
        # There could be multiple .isos in a datastore. Loop over them all
        foreach ($Item in $Result)
        {
            # Write result to console
            Write-Host "Found $($Item.file.path)" -BackgroundColor red
    
            # Create the return object
            [pscustomobject]@{
                Datastore = $_.Name
                Path      = $Result.FolderPath
                File      = $Item.File.Path
                Size      = $Item.File.FileSize
            }
        }
    }
    
    # Dequeue element to let progress update
    # Command is in void brackets to not clutter $list with datastore numbers when receive-job is run
    [void]::($sqCopy.Dequeue())
} 


# Since jobs are run in background, the script will immediately arrive here.
# While the job is still running, update the progress bar
while ($Job.State -eq 'Running') {
    
    # This check is not strictly needed, but will thwart edgecases
    if ($SynchronizedQueue.Count -gt 0) {
        
        # Get the status as a rounded percentage
        $status = [math]::Round(100 - (($SynchronizedQueue.Count / $TotalCount) * 100), 2)
        
        # Splat parameters. This looks prettier than a single line
        $Parameters = @{
            Activity        = "Iterating over Datastores"
            Status          = "$status% complete"
            PercentComplete = $Status
        } 

        # Update the progressbar using the parameters above
        Write-Progress @Parameters
       
        # No need to update status as much as possible
        Start-Sleep -Milliseconds 100
    }
}

# Put the returnelements of the job into variable
$list = Receive-Job -job $Job

#-------------------------------------------| OUTPUT HANDLING |------------------------------------------#

# TODO: Handle your output $list here. 


#---------------------------------------------| DISCONNECT |---------------------------------------------#

Disconnect-VIserver * -Confirm:$false
Write-Host "The script has finished running: Closing"

#-------------------------------------------------| END |------------------------------------------------#
