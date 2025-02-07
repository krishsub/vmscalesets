# Project

This repo is an example of a blue/green deployment on VMSS with zero 
downtime from a workload usage perspective. 

In a blue/green deployment you create two separate but identical 
environments. One environment (say blue) is running the current application
version. You spin up a new identical environment (green in this case) 
where the new application version is deployed. Once the new version is 
validated, it can handleall user traffic and the old version and its 
environment can be deleted. This strategy is repeated for the next 
deployment.

This example illustrates how a blue/green deployment strategy is
implemented for an application deployed on Azure Virtual Machine 
Scale Sets (VMSS). From a user perspective, all calls are handled
gracefully with draining of connections so that the blue/green
deployment results in zero downtime - i.e. not a single request is
lost.

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
workflow to perform the blue/green deployment. The workflow relies on 
[Deploy-Application.ps1](./automation/Deploy-Application.ps1) to do the heavy 
lifting. Comments in this file should explain the blue/green deployment model 
with two VMSS. There are a few pre-requisites before running this workflow. 
The workflow defines 3 environment variables:
    ```
    RESOURCE_GROUP_NAME: <value> (e.g. my-resource-group)
    RELEASE_FOLDER_NAME: <value> (e.g. 1.234)
    BLOB_CONTAINER_NAME: <value> (e.g. appcontainer)
    ```

The storage account created by Bicep should have a blob container with above
`BLOB_CONTAINER_NAME` and containing three assets uploaded to it:
  - [install.ps1](./automation/install.ps1) contains the installation script
  for installing the workload on the VMSS. Place this in the blob container
  root.
  - [azcopy.exe](./automation/azcopy.exe) the azcopy binary. Place this also
  in the blob container root. It will be used by instances in the VMSS to 
  pull files from `RELEASE_FOLDER_NAME` under the `BLOB_CONTAINER_NAME`. 
  - Workload assets uploaded to `RELEASE_FOLDER_NAME`. In this repo example, 
  simply take the `artifact.zip` generated from [code-build.yml](./.github/workflows/code-build.yml), 
  unzip it and upload it's contents to the `RELEASE_FOLDER_NAME` under the
  `BLOB_CONTAINER_NAME`. 

The VMSS Extension results in the first two files (and the .NET hosting
bundle from a public Microsoft link) being copied to each of VMSS instances.
The `install.ps1` is triggered inside the VM and it uses `azcopy` and the 
managed identity of the VM (i.e. the VMSS) to pull in the workload assets from
the `RELEASE_FOLDER_NAME` in the storage account. These assets are used to 
install and configure the workload on each of VM in the VMSS.


## How it works

When a VMSS is hooked up to a load balancer (or application gateway),
the backend pool of the load balancer is automatically configured so
that when new instances are added or removed from the VMSS, the load
balancer's backend pool is reconfigured as well.

This happens automatically and requires no user intervention.

However, the load balancer has no way of knowing that a particular VM is
*going* to be deleted. So for a workload under some load (HTTP/HTTPS traffic),
there are two scenarios that will results in errors for callers.

1. Any in-flight request that is executing on the VM might fail as that 
VM is deleted. 
2. A new request from a caller is routed to a deleted VM before the load 
balancer configuration takes effect.

In order to prevent this scenario, we need to connection drain gracefully.
In essence:
- Don't delete instances in VMSS immediately, but delay their deletion.
- Stop routing (new) requests from callers to instances in VMSS that are
going to be deleted.
- Let existing requests that are being processed from callers continue for
a grace period (i.e. the delay).
- Once we are reasonably sure no traffic is being handled, we are free to
delete the instance(s) in the VMSS.

The above is effectively a simplistic connection drain in
theory. 

## How it works - implementation

- Delay the deletion of the VM instance for some minutes (5-15 minutes). The
[main.bicep](./automation/main.bicep) has a `terminateNotificationProfile`
for the blue/green VMSS. [Link](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-terminate-notification#rest-api)
- In this period, each VM in VMSS can query the Terminate Notification endpoint
and IMDS endpoint (see above links) to see if there is a Terminate event 
meant for itself. All instances in the VMSS receive a terminate notification,
but the notification has a list of which VMs are going to be affected. The
IMDS endpoint has the information on the VM name - as the local machine name
might have a different name than what Azure's Resource Manager gave it. 
- There is no need to poll this Terminate and IMDS endpoint manually. Since 
the load balancer or application gateway will be configured with a health 
probe that pings an application endpoint every x seconds, simply piggyback 
off this. So in the health probe implementation in your workload, simply 
check if there is a terminate event for yourself. If there is, send a 
non-200 HTTP code back to the load balancer health probe. Keep sending
this non-200 HTTP code back to the load balancer health probe. 
- The load balancer health probes will see an unhealthy response coming from
the application. After the configured number of consequentive failures, it
will mark the (VM) instance as unhealthy and stop forwarding traffic to it.
- This is the drain implementation. Within the VM instance, keep sending
unhealthy responses and approve the Terminate event (if required) after a
safe period (safe period = load balancer configuration for `n` retries
at `m` second intervals). If no approval happens, then the instance is force
terminated after `notBeforeTimeout` in the `terminateNotificationProfile`.
Approving the event is simply an optimization instead of waiting for
`notBeforeTimeout` to expire. So, we are sure the drain has completed earlier
than the `notBeforeTimeout`, then the instance doesn't hang around and indicates
to the Azure platform that it can be removed.


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
