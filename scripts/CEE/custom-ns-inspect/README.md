# Customer Namespace Inspect Script
This script executes the inspect command to collect logs and relevant information from
customer namespace. 

Importantly, after gathering the data, the script also scans and removes files containing potentially
sensitive information to ensure safer sharing and archiving.

The script will upload the compressed dump to the [SFTP](https://access.redhat.com/articles/5594481#TOC32).

## Usage

Parameters:
- NAMESPACE: customer namespace name.
- CASEID: customer case identifier

In the management cluster:
```bash
ocm backplane managedjob create CEE/hs-must-gather -p NAMESPACE=my-custom-ns -p CASEID=custom-case-id
```
