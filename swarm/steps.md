# Proxmox Cluster Script Split Plan

Current monolith: scripts/swarm/create_proxmox_cluster.sh

Goal: split into deterministic, measurable stages with explicit contracts.

## Orchestrator Contract

The top-level orchestrator should do only this:

1. Load config path and optional first-node override.
2. Run stage 00 -> 10 -> 20 -> 30 -> 40 -> 50 -> 60 -> 70 -> 80 -> 90.
3. Stop immediately on first non-zero exit code.
4. Pass a single shared state file path to every stage.

Shared state file format:

- Plain shell env file with KEY=VALUE lines.
- Arrays serialized as newline-delimited temp files referenced by path variables.

Required shared state keys:

- CLUSTER_NAME
- CONFIG_FILE
- CONFIG_DIR
- FIRST_NODE_ACCESS_OVERRIDE
- LAB_SSH_USER
- LAB_SSH_PASS
- PROXMOX_SSH_USER
- PROXMOX_SSH_PASS
- CLUSTER_NODE_ADDRESSES_FILE
- NODE_ADDRESSES_FILE
- NODE_KEYS_FILE
- EXPECTED_NODE_NAMES_FILE
- CLUSTER_IP_MAP_FILE
- FIRST_NODE_CLUSTER_ADDRESS
- FIRST_NODE_ACCESS_ADDRESS

## Stage Boundaries

### Stage 00: Validate Inputs and Dependencies

Purpose:

- Validate CLI args.
- Validate config file exists.
- Validate yq binary and version.

Input:

- config path
- optional first-node access override

Output:

- Writes base state keys.

Fail conditions:

- Wrong arg count.
- Missing config file.
- yq missing or not mikefarah v4.

### Stage 10: Parse Config and Secrets

Purpose:

- Parse swarm.name and swarm.nodes.
- Derive node keys, vmids, expected hostnames.
- Parse secrets files.
- Validate uniqueness and counts.

Input:

- state from stage 00
- config yaml

Output:

- CLUSTER_NAME
- credentials
- derived node lists
- optional routable management list

Fail conditions:

- missing swarm.name
- fewer than 2 swarm.nodes
- duplicate cluster IPs
- bad secrets format

### Stage 20: Resolve Management Addresses

Purpose:

- Use explicit swarm.routable_nodes management addresses.
- Build management-to-cluster IP mapping.

Input:

- derived node lists
- management SSH addresses

Output:

- NODE_ADDRESSES_FILE
- CLUSTER_IP_MAP_FILE
- FIRST_NODE_CLUSTER_ADDRESS
- FIRST_NODE_ACCESS_ADDRESS

Fail conditions:

- missing swarm.routable_nodes entries
- routable_nodes and nodes count mismatch

### Stage 30: Preflight Connectivity

Purpose:

- Trust host keys for all management addresses.
- Verify required binaries on each node.

Input:

- node addresses
- lab credentials

Output:

- no new state, pass/fail only

Fail conditions:

- SSH cannot connect
- required tools missing on any node

### Stage 40: Normalize Node Identity

Purpose:

- Enforce deterministic hostnames.
- Rewrite hosts mapping hostname to cluster IP.
- Restart pve-cluster and pvestatd.
- Wait for service readiness.

Input:

- node addresses
- node keys
- cluster name

Output:

- PRIMARY_HOSTNAME_BEFORE_RENAME

Fail conditions:

- hostname mismatch after set
- services not ready after retry window

### Stage 50: Ensure Primary Cluster Exists

Purpose:

- Reconcile primary node paths after rename.
- Create cluster on primary if absent.
- Retry cluster create when IPC is not ready.

Input:

- primary node addresses
- cluster name
- primary cluster link IP

Output:

- cluster exists with expected name on primary

Fail conditions:

- primary belongs to different cluster
- cluster create fails after retries

### Stage 60: Reconcile Primary Metadata

Purpose:

- Reconcile local node name mismatch in corosync.
- Migrate stale node tree data into expected primary path.
- Remove stale node directories.

Input:

- expected node names
- primary hostname

Output:

- normalized /etc/pve node tree on primary

Fail conditions:

- corosync update failure
- stale tree reconciliation failure

### Stage 70: Compute and Prepare Pending Joins

Purpose:

- Determine which nodes still need joining.
- For pending nodes only, enforce empty guest inventory before join.

Input:

- join node address list
- target cluster name

Output:

- PENDING_JOIN_NODE_ADDRESSES_FILE

Fail conditions:

- node belongs to different cluster
- guest cleanup leaves remaining VMs or CTs

### Stage 80: Join Pending Nodes

Purpose:

- Join each pending node using pvecm add and correct link0 cluster IP.
- Validate node count increments.

Input:

- pending join list
- primary cluster address
- cluster IP mapping

Output:

- all pending nodes joined

Fail conditions:

- missing cluster link mapping
- node count does not increase after join

### Stage 90: Postflight Verify

Purpose:

- Wait for quorate cluster.
- Restart management services on all nodes.
- Validate core services active everywhere.
- Validate node count and member names.

Input:

- full node list
- expected member names

Output:

- final cluster health success

Fail conditions:

- not quorate
- services inactive
- node count mismatch
- membership name mismatch

## Recommended Rollout Method

1. Keep scripts/swarm/create_proxmox_cluster.sh as wrapper first.
2. Extract one stage at a time into stage scripts and call them from wrapper.
3. After each extraction, run the same lab config and compare outputs.
4. Do not change behavior and structure in the same commit.

## First Extraction Order

1. Stage 00 and stage 10 (pure parsing and validation).
2. Stage 20 and stage 30 (address resolution and preflight).
3. Stage 40 and stage 50 (identity and create).
4. Stage 60 to stage 90 (reconcile, join, verify).
