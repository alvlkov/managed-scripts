# Customer Namespace Inspect Script
This script executes inspect to collect logs and relevant information from customer namespace. 

The script will upload the compressed inspect collection to specified case. [SFTP](https://access.redhat.com/articles/5594481#TOC32). 

This script will only work if a secret exists in the managed scripts namespace that contains a valid single-use SFTP token and case number.

## Usage

Parameters:
- NAMESPACE: customer namespace name.

In the management cluster:
```bash
ocm backplane managedjob create CEE/hs-must-gather -p NAMESPACE=my-custom-ns
