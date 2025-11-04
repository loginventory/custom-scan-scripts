<#
.SYNOPSIS
    Entry point to fetch data from CyberInsight and write .inv files
    or to post data to the CyberInsight API.

    Configure key parameter in LOGINventory.config (C:\ProgramData\LOGIN\LOGINventory\9.0) and add following settings:

    [------------------------- Required ---------------------------]

    <setting name="CyberInsightApiKey" serializeAs="String">
        <value>Your API KEY</value>
    </setting>
    <setting name="CyberInsightCompanyName" serializeAs="String">
        <value>Your CyberInsight Companyname</value>
    </setting>


    [------------------- Optional (defaults) ----------------------]
    <setting name="CyberInsightEndpoint" serializeAs="String">
        <value>https://ci-gateway-5j2lrwe9.nw.gateway.dev</value>
    </setting>
    <setting name="CyberInsightKeyProperty" serializeAs="String">
        <value>Name</value> <!-- or InventoryNumber if used -->
    </setting>
    <setting name="CyberInsightCriticality" serializeAs="String">
        <value>high|medium</value>
    </setting>
    <setting name="CyberInsightExportQuery" serializeAs="String">
        <value>Vulnerability Assessment\Vulnerability Export</value>
    </setting>
    <setting name="CyberInsightSyncQuery" serializeAs="String">
        <value>Vulnerability Assessment\All Vulnerabilities per Software Package</value>
    </setting>
.PARAMETER params
    Ensure "Action" parameter [Get/Post]
    Ensure "Engine" parameter [psc.exe]
    
#>
param([string]$parameter = "")

Set-StrictMode -Version Latest

# Common helpers (Init/Notify/etc.)
. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")

# 1) Build Common context (encoding, debug & proxy)
$ctx = New-CommonContext -Parameters $parameter -StartLabel 'STARTER'

# Resolve action (default: GET)
$action = $ctx.UserParameters.Action
if ([string]::IsNullOrWhiteSpace($action)) { $action = 'GET' }

# Resolve script paths
$getScript  = Join-Path -Path $PSScriptRoot -ChildPath "CyberInsight\Get-CyberInsightData.ps1"
$postScript = Join-Path -Path $PSScriptRoot -ChildPath "CyberInsight\Post-CyberInsightLiData.ps1"

switch ($action.ToUpperInvariant()) {
    'GET' {
        if (-not (Test-Path -LiteralPath $getScript)) {
            Write-Error "GET script not found: $getScript"
            Write-CommonDebug -Context $ctx -Message ("Starter: GET script missing at {0}" -f $getScript)
            exit 1
        }
        # Execute in current scope so functions/Notify share context if needed
        . $getScript -parameter $parameter
    }
    'POST' {
        if (-not (Test-Path -LiteralPath $postScript)) {
            Write-Error "POST script not found: $postScript"
            Write-CommonDebug -Context $ctx -Message ("Starter: POST script missing at {0}" -f $postScript)
            exit 1
        }
        . $postScript -parameter $parameter
    }
    default {
        Write-Error ("Invalid action: {0} (expected GET or POST)" -f $action)
        Write-CommonDebug -Context $ctx -Message ("Starter: Invalid Action={0}" -f $action)
        exit 1
    }
}
