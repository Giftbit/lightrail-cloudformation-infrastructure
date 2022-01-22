# lightrail-cloudformation-infrastructure

## Continuous Deployment

![CI Overview](/_res/cloudformation-ci.png)

## Deploying

If a new account needs to be deployed:

- If The Production account needs to be deployed
    1. To create the cf-templates S3 bucket go to the web console and start to create a new stack by uploading a template.  Don't go through with the creation.
    2. Deploy the `account-security.yaml` CloudFormation Template
    3. Run the `infrastructure/package.sh` command. Copy the resulting S3 URL.
    4. Deploy the CloudFormation Template to the production account.
    5. Deploy the `infrastructure/ci-roles.yaml` CloudFormation Template to the Staging and Dev accounts
    6. Update the Production LightrailInfrastructureCI's references to the Dev and Staging accounts, and enable managing
       of the accounts.
    
- If the account is not the Production account
    1. Deploy the `infrastructure/ci-roles.yaml` CloudFormation Template to the account in question.
    2. Update the Production LightrailInfrastructureCI's references to the Dev and Staging accounts, and enable managing
       of the accounts.
         
Other elements that will need to be handled manually:

- Synchronizing the configuration buckets from the old to new accounts
- Synchronizing the data lake buckets from old to new accounts
- Snapshotting the Service RDS Database, sharing it with the new account, updating the Services CloudFormation
  configuration to reference the RDS Snapshot ID.

### dev deployments

Requires:

- Dev fob
- Github [access token](https://help.github.com/articles/creating-a-personal-access-token-for-the-command-line/) with `repo` access (no admin scopes). Save in `~/.github/token`.

Run `./auto.sh deploy dev`.
