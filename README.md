# Automation Scripts

A collection of automation scripts. Each folder is a self-contained example
with its own script and README.

## Examples

| Example | Description | Tools |
|---|---|---|
| [bastion-host](bastion-host/) | Builds a VPC with public/private subnets, IGW, route table, security groups, NACLs and two EC2 instances (bastion + private), then tears it all down | Bash, AWS CLI v2 |

## Repository layout

```
automation-scripts/
├── README.md          # this file — index of all examples
├── _template/         # copy this to start a new example
└── <example-name>/
    ├── README.md      # what it does, prerequisites, usage, cleanup
    └── <script>       # the automation itself
```

## Adding a new example

1. Copy the template: `cp -r _template my-new-example`
2. Put your script in the new folder and fill in its `README.md`.
3. Add a row to the **Examples** table above.

## Safety notes

- Scripts that create cloud resources can cost money — always run the cleanup step when done.
- Never commit secrets: keys (`*.pem`), state files, `.env` files and credentials are ignored by `.gitignore`.
