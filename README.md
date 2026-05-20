# aws-nuke

One command, one typed confirmation, account empty. Runs
[ekristen/aws-nuke](https://github.com/ekristen/aws-nuke) inside CodeBuild
against every enabled region. The CloudFormation stack self-destructs at the
end so nothing is left behind.

> **WARNING — this is a kill switch.** It deletes nearly everything in the
> account it runs in. Only point it at sandbox or throwaway accounts. There is
> no undo.

## How it works

```
CloudShell ──► aws-nuke.sh ──► CFN stack ──► CodeBuild ──► aws-nuke ──► (post_build) delete-stack ──► 💥
```

The CFN stack creates only what's needed for the run:

| Resource | Purpose |
|---|---|
| `AWS::IAM::Role` (CodeBuild, `AdministratorAccess`) | aws-nuke needs admin to delete everything |
| `AWS::CodeBuild::Project` | Downloads aws-nuke, generates config, runs it, then deletes the stack |
| `AWS::Logs::LogGroup` | CodeBuild output |

Confirmation is your AWS account ID. **You must type it.** Pastes are detected
by inter-character timing and rejected — a real burst of pasted bytes arrives
in microseconds, real typing is at least tens of milliseconds between
keystrokes.

## Usage

From AWS CloudShell in the target account:

```bash
curl -sSL https://raw.githubusercontent.com/Pablo-Wynistorf/aws-nuke/main/aws-nuke.sh | bash
```

Or, recommended for first-time use, inspect first:

```bash
curl -sSL https://raw.githubusercontent.com/Pablo-Wynistorf/aws-nuke/main/aws-nuke.sh -o aws-nuke.sh
less aws-nuke.sh
bash aws-nuke.sh
```

The script will:

1. Print the caller identity, account ID, and account alias.
2. Refuse if the alias contains `prod`/`prd`/`live` (override with `FORCE=1`).
3. Prompt you to **type** the account ID. Paste attempts are rejected.
4. Deploy the CloudFormation stack.
5. Start the CodeBuild job that runs aws-nuke across every enabled region.
6. Tail the build logs.
7. Wait for the stack to self-destruct (the build's `post_build` phase calls
   `delete-stack`).
8. Exit. The account is empty and the stack is gone.

## Configuration

Environment variables:

| Var | Default | Meaning |
|---|---|---|
| `STACK_NAME` | `aws-nuke` | CloudFormation stack name |
| `AWS_NUKE_VERSION` | `3.49.0` | ekristen/aws-nuke release tag (without `v`) |
| `FORCE` | unset | Set to `1` to bypass alias prod-check |
| `TAIL_LOGS` | `1` | Set to `0` to skip log tailing (still waits for delete) |
| `PASTE_GUARD` | `1` | Set to `0` to disable the anti-paste timing check |
| `TEMPLATE_URL` | GitHub raw URL | Override template source (`file://...` for local) |

## What aws-nuke does NOT touch

- The `aws-nuke` CloudFormation stack itself (filtered out so the run can finish).
- The CodeBuild role used by the run (filtered so aws-nuke doesn't kill its own credentials mid-flight).
- AWS-managed service-linked roles (`AWSServiceRole*`).

Everything else in the account — across every enabled region — is fair game.

## After it finishes

There's nothing to clean up. The stack deleted itself. If you want to run it
again, run the same `curl | bash` command.

If something goes wrong and the stack delete fails (rare — usually a stuck
custom resource you added separately), the script prints the manual cleanup
command before exiting:

```bash
aws cloudformation delete-stack --stack-name aws-nuke
aws cloudformation describe-stack-events --stack-name aws-nuke
```

## Safety summary

1. Script refuses on alias containing `prod`/`prd`/`live` unless `FORCE=1`.
2. You must **type** the account ID. Pastes are rejected by timing.
3. Only digits are accepted while typing — non-digit keys are silently ignored.
4. CodeBuild config excludes the stack itself, so the run can complete and then
   self-clean.
5. `post_build` runs even on build failure, so the stack still tears itself
   down.
