########################################################################
# Escalate-SCOMAlert.ps1
# Hugh Scott
# 2018/07/09
#
# Description:
#   Escalate SCOM alerts based on rules in config file.  Note that this
# may require that the administrator add custom ResolutionStates to 
# SCOM.
#
# THIS CODE IS PROVIDED AS-IS WITH NO WARRANTIES EITHER EXPRESSED OR
# IMPLIED.
#
# Modifications:
# Date         Initials    Description
# 2018/07/09   HMS         -Original
# 2018/07/10   HMS         -Updated; added postPipelineFilter
#
########################################################################

# Load the Operations Manager script API
$momApi = New-Object -ComObject MOM.ScriptAPI

#region Functions
function DateFieldReplace {
param (
    [string]$criteria,
    [int]$timeOffset
)

    # INITIALIZE RETURN VALUE
    [string]$tmpString = ""

    # COMPUTE TIME OFFSET; CAST AS STRING VALUE
    [int]$m_timeOffset = -$timeOffset
    [datetime]$compareDate = (Get-Date).AddMinutes($m_timeOffset).ToUniversalTime()
    [string]$dateString = $compareDate.ToString("MM/dd/yyyy HH:mm:ss")

    If($criteria -match "__LastModified__")
    {
        $tmpString = $criteria.Replace("__LastModified__", $dateString)
    } 
    ElseIf($criteria -match "__TimeRaised__")
    {
        $tmpString = $criteria.Replace("__TimeRaised__", $dateString)
    } 
    Else
    {
        $tmpString = $criteria
    }

    # REPLACE ESCAPED XML CHARACTERS
    $tmpString = $tmpString.Replace("&lt;","<")
    $tmpString = $tmpString.Replace("&gt;",">")

    Return $tmpString

}

function CleanPostPipelineFilter {
param ([string]$postPipelineFilter)
    [string]$tmpString = ""

    # REPLACE ESCAPED XML CHARACTERS
    $tmpString = $postPipelineFilter.Replace("&lt;","<")
    $tmpString = $postPipelineFilter.Replace("&gt;",">")

    Return $tmpString
}
#endregion Functions

# RETRIEVE CONFIGURATION FILE WITH RULES AND EXCEPTIONS
[xml]$configFile= Get-Content 'D:\Admin\Scripts\EscalateScomAlerts\escalate.alert.config'

# MANAGEMENT SERVER
[string]$managementServer = '.'

# LOG FILE
[string]$logFilePath = $configFile.config.settings.outputpath.name
[string]$fileName = "AlertEscalation." + (Get-Date -Format "yyyy.MM.dd") + ".log"
[string]$logFileName = Join-Path $logFilePath $fileName

if ( -not ( Get-Module -Name OperationsManager ) )
{
    Import-Module OperationsManager
}

#region Update Type Data

# Add a UnitMonitor property to the alert which contains the associated unit monitor object
$updateTypeDataUnitMonitorParameters = @{
    TypeName = 'Microsoft.EnterpriseManagement.Monitoring.MonitoringAlert'
    MemberType = 'ScriptProperty'
    MemberName = 'UnitMonitor'
    Value = {
        if ( $this.IsMonitorAlert )
        {
            function GetScomChildNodes
            {
                [CmdletBinding()]
                param
                (
                    [Parameter(Mandatory = $true)]
                    #[Microsoft.EnterpriseManagement.Common.MonitoringHierarchyNode`1[[Microsoft.EnterpriseManagement.Configuration.ManagementPackMonitor, Microsoft.EnterpriseManagement.Core, Version=7.0.5000.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35]]]
                    [System.Object]
                    $MonitoringHierarchyNode
                )

                # Create an array for the unit monitors
                $unitMonitors = @()

                foreach ( $childNode in $MonitoringHierarchyNode.ChildNodes )
                {
                    if ( $childNode.Item.GetType().FullName -eq 'Microsoft.EnterpriseManagement.Configuration.UnitMonitor' )
                    {
                        Write-Verbose -Message "Unit Monitor: $($childNode.Item.DisplayName)"
                        $unitMonitors += $childNode.Item
                    }
                    else
                    {
                        Write-Verbose -Message $childNode.Item.DisplayName
                        Write-Verbose -Message ($childNode.GetType().FullName)
                        GetScomChildNodes -MonitoringHierarchyNode $childNode.Item
                    }
                }

                return $unitMonitors
            }

            # Get the associated monitor from the alert
            if ( $this.IsMonitorAlert )
            {
                $monitor = Get-SCOMClassInstance -Id $this.MonitoringObjectId
            }
            else
            {
                Write-Verbose -Message ( 'The alert "{0}" is not a monitor alert.' -f $this.Name )
                exit
            }
    
            # Get the child nodes of the monitor
            $unitMonitors = @()
            foreach ( $childNode in $monitor.GetMonitorHierarchy().ChildNodes )
            {
                $unitMonitors += GetScomChildNodes -MonitoringHierarchyNode $childNode
            }

            # Get the unit monitor which generated the alert
            $unitMonitor = $unitMonitors | Where-Object -FilterScript { $_.Id -eq $this.MonitoringRuleId }

            return $unitMonitor
        }
    }
}   
if ( -not ( Get-TypeData -TypeName $updateTypeDataUnitMonitorParameters.TypeName ).Members[$updateTypeDataUnitMonitorParameters.MemberName] )
{​​​​​​​
    Update-TypeData @updateTypeDataUnitMonitorParameters
}

# Add a Monitor property to the alert which contains the associated unit monitor object
$updateTypeDataMonitorParameters = @{
    TypeName = 'Microsoft.EnterpriseManagement.Monitoring.MonitoringAlert'
    MemberType = 'ScriptProperty'
    MemberName = 'Monitor'
    Value = {
        Get-SCOMClassInstance -Id $this.MonitoringObjectId
    }
}
if ( -not ( Get-TypeData -TypeName $updateTypeDataMonitorParameters.TypeName ).Members[$updateTypeDataMonitorParameters.MemberName] )
{​​​​​​​
    Update-TypeData @updateTypeDataMonitorParameters
}

# Add a HealthStateSuccess property to the alert which contains the associated unit monitor object
$updateTypeDataHealthStateSuccessParameters = @{
    TypeName = 'Microsoft.EnterpriseManagement.Monitoring.MonitoringAlert'
    MemberType = 'ScriptProperty'
    MemberName = 'HealthStateSuccess'
    Value = {
        return $this.UnitMonitor.OperationalStateCollection |
            Where-Object -FilterScript { $_.HealthState -eq 'Success' } |
            Select-Object -ExpandProperty Name
    }
}
if ( -not ( Get-TypeData -TypeName $updateTypeDataHealthStateSuccessParameters.TypeName ).Members[$updateTypeDataHealthStateSuccessParameters.MemberName] )
{​​​​​​​
    Update-TypeData @updateTypeDataHealthStateSuccessParameters
}

#endregion Update Type Data

$Connection = New-SCManagementGroupConnection $managementServer -PassThru

If($Connection.IsActive)
{
    # INITIALIZE AlertCount
    [int]$AlertCount = 0

    # Alert Storm Processing
    $alertStormRules = $configFile.SelectNodes("//config/alertStormRules/stormRule[@enabled='true']") | Sort-Object {$_.Sequence}

    foreach ( $alertStormRule in $alertStormRules )
    {
        # Get the alerts defined by the criteria and group them by the defined property
        $potentialStormAlertGroups = Get-SCOMAlert -Criteria $alertStormRule.Criteria.InnerText |
            Group-Object -Property $alertStormRule.Property |
            Where-Object -FilterScript { $_.Count -gt 1 }

        # Define a counter which will be used to further subdivide the alerts into groups
        $groupCounter = 0

        # Create a hashtable to store the new groups of alerts
        $stormAlertGroups = @{$groupCounter = @()}

        foreach ( $potentialStormAlertGroup in $potentialStormAlertGroups )
        {
            # Create a variable to base the time elapsed calcluations off of
            $previousDateTime = [System.DateTime]::MinValue
            
            foreach ( $alert in ( $potentialStormAlertGroup.Group | Sort-Object -Property TimeRaised ) )
            {
                # If the alert was raised less than the defined window from the previous alert
                if ( ( $alert.TimeRaised - $previousDateTime ).TotalMinutes -lt $alertStormRule.Window )
                {
                    # Add the alert to the current group
                    $stormAlertGroups[$groupCounter] += $alert
                }
                else
                {
                    # Increment the group counter
                    $groupCounter++

                    # Create a new group
                    $stormAlertGroups[$groupCounter] = @($alert)
                }

                # Update the Previous Date/Time variable
                $previousDateTime = $alert.TimeRaised
            }
        }
        
        # Get the groups which meet the threshold for number of the same alert
        $stormAlerts = $stormAlertGroups.GetEnumerator() |
            Where-Object -FilterScript { $_.Value.Count -ge $alertStormRule.Count }

        foreach ( $stormAlert in $stormAlerts )
        {
            # Get the alerts which were previously tagged as an alert storm
            $oldAlertStormAlerts = $stormAlert.Value |
                Where-Object -FilterScript { ( $_.ResolutionState -eq 18 ) -and $_.TicketID }
            
            if ( $oldAlertStormAlerts.Count -gt 0 )
            {
                # Get the existing "ticket id"
                $ticketId = $oldAlertStormAlerts | Select-Object -ExpandProperty TicketId -Unique
            }
            else
            {
                # Get the alert name
                $alertName = $stormAlert.Value | Select-Object -ExpandProperty Name -Unique

                # Define the "ticket id"
                $ticketId = ( Get-Date -Format 'MM/dd/yyyy hh:mm:ss {0}' ) -f $alertName
                
                    # Get a unique list of monitoring objects
                    $monitoringObjects = $stormAlert.Value |
                        Select-Object -ExpandProperty MonitoringObjectFullName -Unique |
                        Sort-Object
            
                    # Define the string which will be passed in as the "script name" property for LogScriptEvent
                    $stormDescription = "The alert ""$alertName"" was triggered $($stormAlert.Value.Count) times for the following objects:"
            
                    # Define the event details
                    $eventDetails = New-Object -TypeName System.Text.StringBuilder
                    $eventDetails.AppendLine() > $null
                    $eventDetails.AppendLine() > $null
                    $monitoringObjects | ForEach-Object -Process { $eventDetails.AppendLine($_) > $null }
                    $eventDetails.AppendLine() > $null
                    $eventDetails.AppendLine("Internal ticket id: $ticketId") > $null

                    # Get the highest severity of the selected alerts
                    $highestAlertSeverity = $stormAlert.Value.Severity |
                        Sort-Object -Property value__ -Descending |
                        Select-Object -First 1 -Unique

                    # Get the highest priority of the selected alerts
                    $highestAlertPriority = $stormAlert.Value.Priority |
                        Sort-Object -Property value__ -Descending |
                        Select-Object -First 1 -Unique

                    # Determine what the event severity should be
                    if (
                        $highestAlertSeverity -eq 'Error' -and
                        $highestAlertPriority -eq 'High' -and
                        $stormAlert.Value.Monitor.'[System.ConfigItem].AssetStatus'.Value -contains 'Deployed'
                    )
                    {
                        # Error
                        $eventSeverity = 1
                    }
                    elseif (
                        $highestAlertSeverity -in @('Error','Warning') -and
                        $highestAlertPriority -in @('Normal','Low') -and
                        $stormAlert.Value.Monitor.'[System.ConfigItem].AssetStatus'.Value -contains 'Deployed'
                    )
                    {
                        # Warning
                        $eventSeverity = 2
                    }
                    else
                    {
                        # Information
                        $eventSeverity = 0
                    }

                    # Raise an event indicating an alert storm was detected
                    $momApi.LogScriptEvent($stormDescription, 9908, $eventSeverity, $eventDetails.ToString())

            }
            
            # Mark the alert as being part of an alert storm
            $stormAlert.Value |
                Where-Object -FilterScript { $_.ResolutionState -ne 18 } |
                Set-SCOMAlert -ResolutionState 18 -Comment $alertStormRule.Comment.InnerText -TicketId $ticketId
        }
    }
    
    # PROCESS EXCEPTIONS FIRST
    $alertExceptions = $configFile.SelectNodes("//config/exceptions/exception[@enabled='true']") | Sort-Object {$_.Sequence}

    foreach($exception in $alertExceptions)
    {
        # ASSIGN VALUES
        # Write-Host $exception.name
        [string]$criteria = $exception.Criteria.InnerText
        [int]$newResolutionState = $exception.NewResolutionState
        [string]$postPipelineFilter = $exception.PostPipelineFilter #.InnerText
        [string]$comment = $exception.Comment.InnerText
        [string]$name = $exception.Name

        # REPLACE TIME BASED CRITERIA
        if($criteria -match "__TimeRaised__")
        {
            [int]$timeRaisedAge = $exception.TimeRaisedAge
            $criteria = DateFieldReplace $criteria $timeRaisedAge
        }
        if($criteria -match "__LastModified__")
        {
            [int]$lastModifiedAge = $exception.LastModifiedAge
            $criteria = DateFieldReplace $criteria $lastModifiedAge
        }

        # COLLECT ALERTS BASED ON CRITERIA
        If($postPipelineFilter -eq "")
        {
            $alerts = Get-SCOMAlert -Criteria $criteria 
        } 
        Else 
        {
            [string]$cleanString=CleanPostPipelineFilter $postPipelineFilter
            [scriptblock]$filter=[System.Management.Automation.ScriptBlock]::Create($cleanString)

            $alerts = Get-SCOMAlert -Criteria $criteria | Where-Object -FilterScript $filter
        }

        ### UPDATE MATCHING ALERTS TO NEW RESOLUTION STATE
        If($alerts.Count -gt 0)
        {
            $alerts | Set-SCOMAlert -ResolutionState $newResolutionState -Comment $Comment
            # Write-Host $criteria
            $AlertCount = $alerts.Count
            $msg = (Get-Date -Format "yyyy/MM/dd hh:mm:ss") + " : INFO : Updated $AlertCount alert(s) to resolution state $newResolutionState (Exception: $name)."
            # Write-Host "  : $msg"
            Add-Content $logFileName $msg
        }
     

        # RESET EXCEPTION VALUES
        $criteria = $null
        $newResolutionState = $null
        $postPipelineFilter = $null
        $comment = $null
        $name=$null

    }

    # PROCESS RULES SECOND
    $alertRules = $configFile.SelectNodes("//config/rules/rule[@enabled='true']") | Sort-Object {$_.sequence}

    foreach($rule in $alertRules)
    {
        # ASSIGN VALUES
        # Write-Host $rule.name
        [string]$criteria = $rule.Criteria.InnerText
        [int]$newResolutionState = $rule.NewResolutionState
        [string]$postPipelineFilter = $rule.PostPipelineFilter #.InnerText
        [string]$comment = $rule.Comment.InnerText
        [string]$name=$rule.name

        # REPLACE TIME BASED CRITERIA
        if($criteria -match "__TimeRaised__")
        {
            [int]$timeRaisedAge = $rule.TimeRaisedAge
            $criteria = DateFieldReplace $criteria $timeRaisedAge
        }
        if($criteria -match "__LastModified__")
        {
            [int]$lastModifiedAge = $rule.LastModifiedAge
            $criteria = DateFieldReplace $criteria $lastModifiedAge
        }

        # COLLECT ALERTS BASED ON CRITERIA
        if ( [System.String]::IsNullOrEmpty($postPipelineFilter) )
        {
            $alerts = Get-SCOMAlert -Criteria $criteria 
        } 
        else
        {
            [string]$cleanString=CleanPostPipelineFilter $postPipelineFilter
            [scriptblock]$filter=[System.Management.Automation.ScriptBlock]::Create($cleanString)

            $alerts = Get-SCOMAlert -Criteria $criteria | Where-Object -FilterScript $filter
        }

        ### UPDATE MATCHING ALERTS TO NEW RESOLUTION STATE
        If($alerts.Count -gt 0)
        {
            $alerts | Set-SCOMAlert -ResolutionState $newResolutionState -Comment $Comment
            # Write-Host $criteria
            $AlertCount = $alerts.Count
            $msg = (Get-Date -Format "yyyy/MM/dd hh:mm:ss") + " : INFO : Updated $AlertCount alert(s) to resolution state $newResolutionState (Rule: $name)."
            # Write-Host "  : $msg"

            Add-Content $logFileName $msg
        }

        # RESET RULE VALUES
        $criteria = $null
        $newResolutionState = $null
        $postPipelineFilter = $null
        $comment = $null
        $name=$null
    }

}
Else
{
    $msg = (Get-Date -Format "yyyy/MM/dd hh:mm:ss") + " : ERROR : Unable to connect to Management Server"
    Add-Content $logFileName $msg
}