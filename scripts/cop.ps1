#!/bin/pwsh


$global:DebugPreference = $Env:DEBUG_PREFERENCE
$global:VerbosePreference = $Env:DEBUG_PREFERENCE

$DebugPreference = $Env:DEBUG_PREFERENCE
$VerbosePreference = $Env:DEBUG_PREFERENCE

Write-Information -MessageData "Starting prometheus vsphere exporter" -InformationAction Continue

Set-PowerCLIConfiguration -InvalidCertificateAction:Ignore -Confirm:$false  | Out-Null 

Write-Information -MessageData "Connecting to $($Env:VCENTER_URI)" -InformationAction Continue
$server = Connect-VIServer -Server $Env:VCENTER_URI -Credential (Import-Clixml $Env:VCENTER_SECRET_PATH)

$hashTable = New-Object System.Collections.Hashtable
$availableResourcesHash = [System.Collections.Hashtable]::Synchronized($hashTable)

# TODO: Multiple vCenters

Write-Information -MessageData "Starting statistics thread" -InformationAction Continue


# TODO: If multiple clusters are available
# round-robin


$resourceThread = Start-ThreadJob -name resource -ThrottleLimit 10 -ScriptBlock {
	$DebugPreference = $Env:DEBUG_PREFERENCE
	$VerbosePreference = $Env:DEBUG_PREFERENCE
	:forever while ($true) {
		$tempServer = $using:server

		$datacenters = Get-Datacenter -Server $tempServer
		foreach ($dc in $datacenters) {

			$clusters = Get-Cluster -Server $tempServer -Location $dc
			foreach ($c in $clusters) {

				Write-Verbose "$($c.Name)"

				$summary = $c.ExtensionData.Summary
				$us = $c.ExtensionData.Summary.UsageSummary

				Write-Verbose ($us | Format-Table | Out-String) 
				if ($summary.NumHosts -gt 2) {
					Write-Verbose "Hosts Quantity: $($summary.NumHosts)"
			
					$cpuDemand = $us.CpuDemandMhz / $us.TotalCpuCapacityMhz
					$memoryDemand = $us.MemDemandMB / $us.TotalMemCapacityMB

					$key = [string]::Format("{0}-{1}-{2}", $tempServer.Name, $dc.Name, $c.Name) 

					$perfOk = $false
					if ($cpuDemand -lt 0.8 -and $memoryDemand -lt 0.8) {
						Write-Verbose "CPU and Memory Demand less than 80%"
						$ready = @()
						$perfOk = $true


						# If cluster cpu and memory demand is less than
						# 80% check if the ci- virtual machines readiness 
						$virtualMachines = Get-VM -Location $c -Name "ci-*"

						foreach ($v in $virtualMachines) {
							$readiness = $v.ExtensionData.Summary.QuickStats.OverallCpuReadiness

							# TODO: this value as a configuration item

							# If readiness is greater than 5%
							# add value to $ready array
							if ($readiness -ge 5) {
								$ready.Add($readiness)
							}
						}


						# TODO: this value as a configuration item

						# If there are five or more virtual machines with readiness
						# check the average value of readiness
						if ($ready.Count -ge 5) {
							Write-Verbose "More than five virtual machines readiness: $($ready.Count)"
							$avgReady = $ready | Measure-Object -Average

							# TODO: this value as a configuration item

							# If average readiness is higher than 5% 
							# Performance is not ok
							if ($avgReady -gt 5) {
								Write-Verbose "Average readiness is above 5%: $($avgReady)"
								$perfOk = $false
							}
						}

						if ($perfOk) {
							$portGroups = @()
							$dsName = ""
							foreach ($dsMoRef in $c.ExtensionData.Datastore) {
								$ds = Get-View $dsMoRef
							
								if ($ds.Summary.Type -eq "vsan") {
									$dsName = $ds.Summary.Name
									break
								}
							}

							foreach ($pgMoRef in $c.ExtensionData.Network) {
								$pg = Get-View $pgMoRef

								if ($pg.Name -contains "ci-vlan-*") {
									$portGroups.Add($pg.Name)
								}
							}

							if (-not $tempAvailableResourcesHash.ContainsKey($key)) {
								$resources = [PSCustomObject]@{
									Datacenter = $dc.Name 
									Cluster    = $c.Name
									Datastore  = $dsName

									# Should this be a queue?
									PortGroups = $portGroups
								}
								Write-Verbose "Resource: Before Add"
								$tempAvailableResourcesHash = $using:availableResourcesHash
								$tempAvailableResourcesHash[$key] = $resources
								Write-Verbose "Resource: After Add"
							}
						}
						else {
							$tempAvailableResourcesHash = $using:availableResourcesHash
							$tempAvailableResourcesHash.Remove($key)
						}
					} else {
						$tempAvailableResourcesHash = $using:availableResourcesHash
						$tempAvailableResourcesHash.Remove($key)
					}
				}
			}
		}


		Start-Sleep -Seconds $Env:SCRAPE_DELAY

		$endTime = Get-Date
		Write-Verbose "Resources: End Time: $($endTime)"
	}
}


Write-Information -MessageData "Starting HTTPd thread" -InformationAction Continue

# Below section is from the following gist:
# https://gist.github.com/rminderhoud/c603a0a30587ae5c957b211ba386bf37

$webThread = Start-ThreadJob -Name web -ScriptBlock {
	$DebugPreference = $Env:DEBUG_PREFERENCE
	$http = [System.Net.HttpListener]::new()
	$http.Prefixes.Add("http://*:8080/")

	Write-Information -MessageData "HTTPd: Starting" -InformationAction Continue
	$http.Start()

	if ($http.IsListening) {
		Write-Information -MessageData "HTTPd: Ready" -InformationAction Continue
	}

	try {
		while ($http.IsListening) {
			Write-Debug "HTTPd: Before GetContextAsync()"
			$contextTask = $http.GetContextAsync()
			Write-Debug "HTTPd: Before GetAwaiter()"
			$startTime = Get-Date
			Write-Debug "HTTPd: Waiter Start: $($startTime)"
			$context = $contextTask.GetAwaiter().GetResult()


			if ($context.Request.HttpMethod -eq 'GET' -and $context.Request.RawUrl -eq '/resource') {
				Write-Debug "$($context.Request.UserHostAddress) => $($context.Request.Url)"
				$tempResourcesHash = $using:availableResourcesHash
				$resourcesString = ""
				if ($tempResourcesHash.Count -gt 0) {
					$resourcesString = ConvertTo-Json -InputObject $tempResourcesHash
				}

				$buffer = [System.Text.Encoding]::UTF8.GetBytes([string]$resourcesString) # convert htmtl to bytes
				$context.Response.ContentLength64 = $buffer.Length
				$context.Response.OutputStream.Write($buffer, 0, $buffer.Length) #stream to broswer
				$context.Response.OutputStream.Close() # close the response
			}
			$endTime = Get-Date
			Write-Debug "HTTPd: Waiter End: $($endTime)"
		}
	}
	finally {
		$http.Stop()
	}
}

while ($true) {
	Start-Sleep -Seconds $Env:THREAD_STATUS_DELAY
	Get-Job

	Write-Information -InformationAction Continue -MessageData "Resource: Thread Results"
	$resourceOutput = Receive-Job -Job $resourceThread
	$resourceOutput

	Write-Information -InformationAction Continue -MessageData "HTTPd: Thread Results"
	$webOutput = Receive-Job -Job $webThread
	$webOutput
}
