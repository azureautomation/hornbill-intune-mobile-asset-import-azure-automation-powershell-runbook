<#PSScriptInfo

.VERSION 1.2

.GUID cb45bb07-b39b-4398-9903-4766c04c4cdf

.AUTHOR steve.goldthorpe@hornbill.com

.COMPANYNAME Hornbill

.TAGS hornbill powershell intune azure automation workflow runbook

.RELEASENOTES
1.2 - Removed dependency on PSIntuneAuth module 

#>

<# 

.DESCRIPTION 
  Azure Automation Runbook to retrieve mobile assets from Intune, and import them into your Hornbill instance CMDB. 

#> 

#Requires -Module @{ModuleVersion = '1.1.0'; ModuleName = 'HornbillAPI'}
#Requires -Module @{ModuleVersion = '1.2.0'; ModuleName = 'HornbillHelpers'}

# Define Intune Params
$AutomationCred = "IntuneAutomation"
$AutomationVar = "AppClientID"
$Resource = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$top=100"
$TenantName = "YourTenantName.onmicrosoft.com"

# Define Hornbill Params
$APIKey = "APIKey" # Points to your Runbook variable that holds your Hornbill API Key
$InstanceID = "Instance" # Points to your Runbook variable that holds your Hornbill instance ID
$AssetClass = "mobileDevice" # Asset Class for Mobile Devices in your Hornbill instance
$AssetType = "77" # Primary Key for the "Smart Phone" asset type in your Hornbill instance
$AssetEntity = "AssetsMobileDevice" # Entity name of the Hornbill entity used to check for existing assets 
$AssetUniqueColumn = "h_serial_number" # Column in the above entity used to check for existing assets

#Import required modules
try {
    Import-Module -Name AzureAD -RequiredVersion 2.0.2.140 -ErrorAction Stop -WarningAction Stop
    Import-Module -Name HornbillAPI -ErrorAction Stop -WarningAction silentlyContinue
    Import-Module -Name HornbillHelpers -MinimumVersion 1.2.0 -ErrorAction Stop -WarningAction silentlyContinue
}
catch {
    Write-Warning -Message "Failed to import modules: $($_.Exception.Message)"
}

#Read Creds and Vars
$Credential = Get-AutomationPSCredential -Name $AutomationCred
$ClientID = Get-AutomationVariable -Name $AutomationVar
$APIKey = Get-AutomationVariable -Name $APIKey
$Instance = Get-AutomationVariable -Name $InstanceID

# Create Hornbill instance details
Set-HB-Instance -Instance $Instance -Key $APIKey

$Headers = New-HB-GraphAccessToken -TenantName $TenantName -UserName $Credential.UserName -Password $Credential.Password -ClientID $ClientID
$NewHeaders = @{"Authorization" = $Headers.Authorization; "Content-Type" = "application/json" };

#�Now get pages of assets, and update/create into Hornbill as appropriate
$LastLoop = $false
$AssetsProcessed = @{
    "created"           = 0
    "primaryupdated"    = 0
    "relatedupdated"    = 0
    "found"             = 0
    "totalupdated"      = 0
    "skipupdateprimary" = 0
    "skipupdaterelated" = 0
}
while ($LastLoop -eq $false -and $Resource -ne "") {
    Write-Output -InputObject ("Retrieving devices from: " + $Resource)
    $ManagedDevices = Invoke-RestMethod -Uri $Resource -Method Get -Headers $NewHeaders
    $DeviceCount = 0
    if ($ManagedDevices.PSobject.Properties.name -match "@odata.count") {
        $DeviceCount = $ManagedDevices."@odata.count"
    }
    $Resource = ""
    if ($ManagedDevices.PSobject.Properties.name -match "@odata.nextLink") {
        $Resource = $ManagedDevices."@odata.nextLink"
    }

    if ($DeviceCount -eq 0) {
        $LastLoop = $true
    }
    else {
        $DevicesArr = $ManagedDevices.Value
        if ($DevicesArr -ne $null) {
            foreach ($Device in $DevicesArr) {
                $AssetsProcessed.found++
                #Set Date/Time
                $CurrDateTime = Get-Date -format "yyyy/MM/dd HH:mm:ss"
                #Does asset exist?
                $AssetIDCheck = Get-HB-AssetID $Device.serialNumber $AssetEntity $AssetUniqueColumn
                $ExistingAsset = $false
                if ($AssetIDCheck.AssetID -ne $null) {
                    $ExistingAsset = $true
                    Write-Output -InputObject ("Matched Hornbill asset record found, ID: " + $AssetIDCheck.AssetID)
                    $UpdatedPrimary = $false
                    $UpdatedRelated = $false
                    #Asset Exists - Update Primary Entity Data First
                    Add-HB-Param        "application" "com.hornbill.servicemanager"
                    Add-HB-Param        "entity" "Asset"
                    Add-HB-Param        "returnModifiedData" "true"
                    Open-HB-Element     "primaryEntityData"
                    Open-HB-Element     "record"
                    Add-HB-Param        "h_pk_asset_id" $AssetIDCheck.AssetID
                    Add-HB-Param        "h_class" $AssetClass
                    Add-HB-Param        "h_asset_urn" ("urn:sys:entity:com.hornbill.servicemanager:Asset:" + $AssetIDCheck.AssetID)
                    if ($Device.userDisplayName -ne $null -and $Device.userPrincipalName -ne $null) {
                        $OwnerURN = "urn:sys:0:" + $Device.userDisplayName + ":" + $Device.userPrincipalName
                        Add-HB-Param        "h_owned_by" $OwnerURN
                        Add-HB-Param        "h_owned_by_name" $Device.userDisplayName
                    }
                    Add-HB-Param        "h_name" $Device.deviceName
                    Add-HB-Param        "h_description" $Device.managedDeviceName
                    Close-HB-Element    "record"
                    Close-HB-Element    "primaryEntityData"
                    $UpdateAsset = Invoke-HB-XMLMC "data" "entityUpdateRecord"

                    if ($UpdateAsset.status -eq 'ok' -and $UpdateAsset.params.primaryEntityData.PSobject.Properties.name -match "record") {
                        $UpdatedPrimary = $true
                        $AssetsProcessed.primaryupdated++
                        Write-Output -InputObject ("Asset Primary Record Updated: " + $AssetIDCheck.AssetID)
                    }
                    else {
                        $ErrorMess = $UpdateAsset.error

                        if ($UpdateAsset.params.primaryEntityData.PSobject.Properties.name -notmatch "record") {
                            Write-Output ("There are no primary entity values to update for asset with primary key: " + $AssetIDCheck.AssetID)
                            $AssetsProcessed.skipupdateprimary++
                        }
                        else {
                            Write-Warning ("Error Updating Primary Asset Record " + $AssetIDCheck.AssetID + ": " + $ErrorMess)
                            $AssetsProcessed.skipupdateprimary++
                            Continue
                        }
                    }

                    # Now update related record information
                    Add-HB-Param        "application" "com.hornbill.servicemanager"
                    Add-HB-Param        "entity" "Asset"
                    Add-HB-Param        "returnModifiedData" "true"
                    Open-HB-Element     "primaryEntityData"
                    Open-HB-Element     "record"
                    Add-HB-Param        "h_pk_asset_id" $AssetIDCheck.AssetID
                    Close-HB-Element    "record"
                    Close-HB-Element    "primaryEntityData"
                    Open-HB-Element     "relatedEntityData"
                    Add-HB-Param        "relationshipName" "AssetClass"
                    Add-HB-Param        "entityAction" "update"
                    Open-HB-Element     "record"
                    Add-HB-Param        "h_type" $AssetType
                    Add-HB-Param        "h_capacity" $Device.totalStorageSpaceInBytes
                    Add-HB-Param        "h_description" $Device.managedDeviceName
                    Add-HB-Param        "h_imei_number" $Device.imei
                    Add-HB-Param        "h_mac_address" $Device.wiFiMacAddress
                    Add-HB-Param        "h_manufacturer" $Device.manufacturer
                    Add-HB-Param        "h_model" $Device.model
                    Add-HB-Param        "h_name" $Device.deviceName
                    Add-HB-Param        "h_os_version" ($Device.operatingSystem + " " + $Device.osVersion)
                    Add-HB-Param        "h_phone_number" $Device.phoneNumber
                    Add-HB-Param        "h_serial_number" $Device.serialNumber
                    Close-HB-Element    "record"
                    Close-HB-Element    "relatedEntityData"
                    $UpdateAssetRelated = Invoke-HB-XMLMC "data" "entityUpdateRecord"
                    if ($UpdateAssetRelated.status -eq 'ok') {
                        $UpdatedRelated = $true
                        $AssetsProcessed.relatedupdated++
                        Write-Output -InputObject ("Asset Related Record Updated: " + $AssetIDCheck.AssetID)
                    }
                    else {
                        if ($UpdateAssetRelated.params.relatedEntityData.PSobject.Properties.name -notmatch "record") {
                            Write-Output ("There are no related entity values to update for asset with primary key: " + $AssetIDCheck.AssetID)
                            $AssetsProcessed.skipupdaterelated++
                        }
                        else {
                            Write-Warning ("Error Updating Related Asset Record " + $AssetIDCheck.AssetID + ": " + $ErrorMess)
                            $AssetsProcessed.skipupdaterelated++
                            Continue
                        }
                    }

                    if ($UpdatedPrimary -eq $true -or $UpdatedRelated -eq $true) {
                        $AssetsProcessed.totalupdated++
                        #Update Last Udated fields
                        Add-HB-Param        "application" "com.hornbill.servicemanager"
                        Add-HB-Param        "entity" "Asset"
                        Open-HB-Element     "primaryEntityData"
                        Open-HB-Element     "record"
                        Add-HB-Param        "h_pk_asset_id" $AssetIDCheck.AssetID
                        Add-HB-Param        "h_last_updated" $CurrDateTime
                        Add-HB-Param        "h_last_updated_by" "Azure Intune Import"
                        Close-HB-Element    "record"
                        Close-HB-Element    "primaryEntityData"
                        $UpdateLastAsset = Invoke-HB-XMLMC "data" "entityUpdateRecord"
                        if ($UpdateLastAsset.status -ne 'ok') {
                            Write-Warning ("Asset updated but error returned updating Last Updated values: " + $UpdateLastAsset.error)    
                        }
                    }

                }
                else {
                    #Asset doesn't exist - Add
                    Add-HB-Param        "application" "com.hornbill.servicemanager"
                    Add-HB-Param        "entity" "Asset"
                    Add-HB-Param        "returnModifiedData" "true"
                    Open-HB-Element     "primaryEntityData"
                    Open-HB-Element     "record"
                    Add-HB-Param        "h_class" $AssetClass
                    Add-HB-Param        "h_type" $AssetType
                    Add-HB-Param        "h_last_updated" $CurrDateTime
                    Add-HB-Param        "h_last_updated_by" "Azure Intune Import"
                    if ($Device.userDisplayName -ne $null -and $Device.userPrincipalName -ne $null) {
                        $OwnerURN = "urn:sys:0:" + $Device.userDisplayName + ":" + $Device.userPrincipalName
                        Add-HB-Param        "h_owned_by" $OwnerURN
                        Add-HB-Param        "h_owned_by_name" $Device.userDisplayName
                    }
                    Add-HB-Param        "h_name" $Device.deviceName
                    Add-HB-Param        "h_description" $Device.managedDeviceName
                    Close-HB-Element    "record"
                    Close-HB-Element    "primaryEntityData"
                    Open-HB-Element     "relatedEntityData"
                    Add-HB-Param        "relationshipName" "AssetClass"
                    Add-HB-Param        "entityAction" "insert"
                    Open-HB-Element     "record"
                    Add-HB-Param        "h_type" $AssetType
                    Add-HB-Param        "h_capacity" $Device.totalStorageSpaceInBytes
                    Add-HB-Param        "h_description" $Device.managedDeviceName
                    Add-HB-Param        "h_imei_number" $Device.imei
                    Add-HB-Param        "h_mac_address" $Device.wiFiMacAddress
                    Add-HB-Param        "h_manufacturer" $Device.manufacturer
                    Add-HB-Param        "h_model" $Device.model
                    Add-HB-Param        "h_name" $Device.deviceName
                    Add-HB-Param        "h_os_version" ($Device.operatingSystem + " " + $Device.osVersion)
                    Add-HB-Param        "h_phone_number" $Device.phoneNumber
                    Add-HB-Param        "h_serial_number" $Device.serialNumber
                    Close-HB-Element    "record"
                    Close-HB-Element    "relatedEntityData"
                    $InsertAsset = Invoke-HB-XMLMC "data" "entityAddRecord"
                    if ($InsertAsset.status -eq 'ok') {
                        $AssetsProcessed.created++
                        Write-Output -InputObject ("Asset Imported: " + $InsertAsset.params.primaryEntityData.record.h_pk_asset_id)
                        #Now update the asset with its URN
                        Add-HB-Param        "application" "com.hornbill.servicemanager"
                        Add-HB-Param        "entity" "Asset"
                        Open-HB-Element     "primaryEntityData"
                        Open-HB-Element     "record"
                        Add-HB-Param        "h_pk_asset_id" $InsertAsset.params.primaryEntityData.record.h_pk_asset_id
                        Add-HB-Param        "h_asset_urn" ("urn:sys:entity:com.hornbill.servicemanager:Asset:" + $InsertAsset.params.primaryEntityData.record.h_pk_asset_id)
                        Close-HB-Element    "record"
                        Close-HB-Element    "primaryEntityData"
                        $UpdateAsset = Invoke-HB-XMLMC "data" "entityUpdateRecord"
                        if ($UpdateAsset.status -eq 'ok') {
                        }
                        else {
                            Write-Warning ("Error Updating Asset URN: " + $UpdateAsset.error)    
                        }

                    }
                    else {
                        Write-Warning ("Error Creating Asset: " + $InsertAsset.error)
                    }
                }
            }
        }
    }
}
""
"IMPORT COMPLETE"
""
Write-Output -InputObject ("Assets Found:" + $AssetsProcessed.found)
Write-Output -InputObject ("Assets Created:" + $AssetsProcessed.created)
Write-Output -InputObject ("Assets Updated:" + $AssetsProcessed.created)
""
Write-Output -InputObject ("* Primary Record Updated:" + $AssetsProcessed.primaryupdated)
Write-Output -InputObject ("* Primary Record Update Skipped:" + $AssetsProcessed.skipupdateprimary)
Write-Output -InputObject ("* Related Record Updated:" + $AssetsProcessed.relatedupdated)
Write-Output -InputObject ("* Related Record Update Skipped:" + $AssetsProcessed.skipupdaterelated)