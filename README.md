# Project

> This repo is an example of a blue/green deployment on VMSS with zero 
> downtime from a workload usage perspective.

There are a few pieces to understand from a top-level perspective:

- [code-build.yml](./.github/workflows/code-build.yml) has the build workflow
to build the [source code](./source/) that relies on 
[VMSS Terminate Notification](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-terminate-notification) 
and the [Azure Instance Metadata Service](https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service)
to respond to health probes from an Azure Load Balancer or Application Gateway.
- [setup-azure-environment.yml](./.github/workflows/setup-azure-environment.yml)
has the workflow that deploys Azure Resources using Bicep, configures two VMSS,
two jumpbox VMs and a storage account among others in order to illustrate various
services and their interactions. The workflow relies on the following automation 
pieces:
  - [Pre-Deploy.ps1](./automation/Pre-Deploy.ps1)
  - [main.bicep](./automation/main.bicep)
  - [Post-Deploy.ps1](./automation/Post-Deploy.ps1)
- [deploy-application.yml](./.github/workflows/deploy-application.yml) has the
workflow to perform the blue/green deployment. There are a few pre-requisites
before running this workflow. The workflow defines 3 environment variables:
```
RESOURCE_GROUP_NAME: <value> (e.g. my-resource-group)
RELEASE_FOLDER_NAME: <value> (e.g. 1.234)
BLOB_CONTAINER_NAME: <value> (e.g. appcontainer)
```
The storage account created should have a blob container with above
name and containing two artifacts uploaded to it:
  - [install.ps1](./automation/install.ps1) contains the installation script
  for installing the workload on the VMSS.
  - [azcopy.exe](./automation/azcopy.exe) the azcopy binary that pulls
  files from `RELEASE_FOLDER_NAME` under the `BLOB_CONTAINER_NAME`. In this
  repo example, simply take the artifact generated from 
  [code-build.yml](./.github/workflows/code-build.yml), unzip it and upload 
  it's contents to the `RELEASE_FOLDER_NAME`.
  - The workflow relies on [Deploy-Application.ps1](./automation/Deploy-Application.ps1)
    to do the heavy lifting. Comments in this file should explain the
    blue/green deployment model with two VMSS.

## Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
