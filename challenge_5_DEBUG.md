# Challenge 5 — Debug: app runs, but external `curl :4444` hangs

**Scenario.** Pipeline is green. On the EC2 box, `curl localhost:4444` returns the
expected JSON — the app is up and listening. From my laptop,
`curl http://<public-ip>:4444` **hangs forever** until Ctrl-C. It does *not* say
"connection refused".

**The symptom is the biggest clue.** A *hang* means my SYN packets are being
**silently dropped** — no response of any kind comes back, so the TCP handshake
never completes and the client waits out its timeout. That is the fingerprint of
a packet filter (Security Group / NACL / host firewall), not of the app. A closed
or wrong-bound port would instead bounce a TCP **RST** straight back and curl
would print **"connection refused" immediately**. So whatever is wrong sits in the
**network path**, and anything that would produce a fast refusal — the app bound
to `127.0.0.1`, the wrong port, the process being down — is effectively ruled out
by the fact that we hang rather than get refused.

## Two ranked hypotheses

1. **(Most likely) The Security Group has no inbound rule allowing `tcp/4444`
   from my client IP** (rule missing, or its source is scoped to a CIDR that
   isn't my laptop). Security Groups *default-deny* and **drop** unmatched inbound
   traffic with no reply — which is exactly a hang, and the SG is the one filter
   we hand-configure, so it's the first suspect.

2. **A stateless Network ACL on the subnet is dropping the traffic** — most
   often by allowing the inbound SYN on `4444` but **not** allowing the
   **outbound ephemeral return ports (1024–65535)**, so the SYN-ACK can't leave.
   NACLs are stateless (return traffic isn't auto-allowed like in a SG), so a
   custom NACL that looks "open enough" still produces a one-way black hole → hang.
   *(Same class of cause if a host firewall like `ufw`/`iptables` were set to
   `DROP` — also silent, also a hang — but on the stock Ubuntu AMI that's
   inactive, so it ranks below the NACL.)*

## One verification step per hypothesis

1. **Check the Security Group inbound rules** — does `tcp/4444` allow my source?
   ```bash
   aws ec2 describe-security-groups --group-ids <sg-id> \
     --query "SecurityGroups[].IpPermissions[?ToPort==\`4444\`]" --output json
   ```
   (Console: EC2 → instance → **Security** tab → inbound rules.) No 4444 entry, or
   a source CIDR that doesn't cover my IP → **H1 confirmed.**

2. **Check the subnet's Network ACL — inbound 4444 *and* outbound ephemeral.**
   ```bash
   aws ec2 describe-network-acls \
     --filters Name=association.subnet-id,Values=<subnet-id> \
     --query "NetworkAcls[].Entries" --output table
   ```
   (Console: VPC → **Network ACLs** → the subnet's ACL → Inbound + Outbound.) If
   inbound `4444` is missing/denied, or outbound `1024–65535` isn't allowed → **H2
   confirmed.**

   *Tie-breaker that splits the two cleanly:* run `sudo tcpdump -ni any tcp port 4444`
   on the instance while curling from the laptop. SG and inbound-NACL drops happen
   **before** the guest OS, so you'll see **no packet at all** (→ H1, or inbound
   NACL). If you see the SYN arrive but no SYN-ACK make it back, it's the **return
   path** (→ H2 outbound-ephemeral / host firewall).

## Fix (minimal)

- **If H1:** add a single inbound SG rule — Custom TCP, port `4444`, source
  `0.0.0.0/0` (the verifier curls from outside AWS). In this repo that's the
  `ingress` block already in `terraform/main.tf`; via console it's
  *Edit inbound rules → Add rule → Custom TCP → 4444 → 0.0.0.0/0*.
- **If H2:** on the subnet's NACL, allow **inbound `tcp/4444`** *and* **outbound
  `tcp 1024–65535`** (the stateless return path) — or simply associate the subnet
  with the permissive **default** NACL.

No Terraform rewrite, no new VPC — one SG rule (or one/two NACL entries) closes it.

## The underlying lesson

A **dropped** packet gets *no* answer, so the client blocks waiting for a reply
that never arrives — you **hang** until timeout; that's a firewall silently
filtering traffic in the path. A packet that **reaches a closed port** makes the
host send back a TCP **RST**, which the client sees instantly as **"connection
refused."** So *hang ⇒ filtered/dropped in the network*; *refused ⇒ the packet
arrived but nothing was listening* — the symptom alone tells you whether to look
at the firewall or at the app.
