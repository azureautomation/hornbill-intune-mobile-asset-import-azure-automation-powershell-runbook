Hornbill Intune Mobile Asset Import - Azure Automation Powershell Runbook
=========================================================================

            

This is an Azure Automation Powershell Runbook which will retrieve mobile assets from Intune, and import them into your Hornbill instance CMDB.


**REQUIRED**


Requires the HornbillAPI, HornbillHelpers and AzureAD to be installed against your Azure Automation Account. These can be installed via the PowershellGallery:


https://www.powershellgallery.com/packages/HornbillAPI/


https://www.powershellgallery.com/packages/HornbillHelpers/


The script requires you to create an Azure AD App Registration for accessing the Microsoft Intune Graph API, instructions can be found: https://www.scconfigmgr.com/2017/08/03/create-an-azure-ad-app-registration-for-accessing-microsoft-intune-graph-api-with-powershell/


You will also need to create an Automation Credential to contain account details to generate an access token, and Automation Variables to hold:


  *  The Client ID for the Azure AD App Registration

  *  Your Hornbill Instance ID 
  *  An API key for a user on your Hornbill instance


Once these have been created, you can then populate the AutomationCred, AutomationVar, APIKey and InstanceID variables with the names of these credentials/variables.


**AUTHOR**


Hornbill Service Management Limited


**LICENSE**


https://wiki.hornbill.com/index.php/The_Hornbill_Community_License_(HCL)


 

 

        
    
TechNet gallery is retiring! This script was migrated from TechNet script center to GitHub by Microsoft Azure Automation product group. All the Script Center fields like Rating, RatingCount and DownloadCount have been carried over to Github as-is for the migrated scripts only. Note : The Script Center fields will not be applicable for the new repositories created in Github & hence those fields will not show up for new Github repositories.
