Scenario:

An application team needs to migrate from on-prem to the Azure Cloud in a brand new subscription with no current infrastructure.  
How would you describe the required environment below using Terraform?  Assume the mechanism Terraform will use to deploy has all appropriate rights.


Required Infrastructure:

1 Virtual machine
1 storage account with private endpoint
1 key vault with private endpoint
1 Azure Firewall
 

Technical Details:

Each piece of required infrastructure must be deployed in its own subnet
Every subnet must have an NSG attached to it
The Virtual machine will need to read information from Blob storage and read a secret from the Key Vault
Traffic between each piece of infrastructure cannot cross subnet boundaries directly
Traffic must be inspected by the Azure Firewall Device before crossing a subnet boundary
