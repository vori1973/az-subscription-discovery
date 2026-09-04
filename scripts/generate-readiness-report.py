#!/usr/bin/env python3
"""Generate a human-readable Markdown readiness report from discover-subscription JSON output.

This is a pure, offline transform: it reads a JSON file already produced by
discover-subscription.sh/.ps1 and writes a Markdown report. It issues no Azure API calls and
does not modify the input file.
"""

import argparse
import json
import sys


DEFAULT_QUOTA_THRESHOLD = 0.8


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Render a discover-subscription JSON file as a Markdown readiness report."
    )
    parser.add_argument("input", help="Path to a discovery JSON file")
    parser.add_argument(
        "-o", "--output", help="Path to write the Markdown report (default: stdout)"
    )
    parser.add_argument(
        "--quota-threshold",
        type=float,
        default=DEFAULT_QUOTA_THRESHOLD,
        help=(
            "Usage ratio (currentValue/limit) at or above which a quota entry is flagged as a "
            f"risk (default: {DEFAULT_QUOTA_THRESHOLD})"
        ),
    )
    return parser.parse_args(argv)


def load_discovery_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as exc:
        raise SystemExit(f"Error: could not read input file '{path}': {exc}")

    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Error: input file '{path}' is not valid JSON: {exc}")


def section_unavailable(title):
    return f"## {title}\n\n_Not available in this discovery output._\n"


def render_meta(data):
    if "meta" not in data:
        return section_unavailable("Subscription")
    meta = data["meta"]
    lines = ["## Subscription", ""]
    if "generatedAt" in meta:
        lines.append(f"- **generatedAt**: {meta['generatedAt']}")
    if "tenantId" in meta:
        lines.append(f"- **tenantId**: {meta['tenantId']}")
    subscriptions = meta.get("subscriptions")
    if subscriptions:
        lines.append(f"- **subscriptions**: {', '.join(subscriptions)}")
    if "runAs" in meta:
        lines.append(f"- **runAs**: {meta['runAs']}")
    return "\n".join(lines) + "\n"


def render_resource_groups(data):
    if "resourceGroups" not in data:
        return section_unavailable("Resource Groups")
    rgs = data["resourceGroups"] or []
    lines = ["## Resource Groups", "", f"Total: {len(rgs)}", ""]
    if rgs:
        lines.append("| Name | Location |")
        lines.append("|---|---|")
        for rg in rgs:
            lines.append(f"| {rg.get('name', '')} | {rg.get('location', '')} |")
    return "\n".join(lines) + "\n"


def render_networking(data):
    if "networking" not in data:
        return section_unavailable("Networking Topology")
    networking = data["networking"] or {}
    vnets = networking.get("vnets") or []
    constraints = data.get("architectureConstraints") or {}
    hub = constraints.get("hubPeering")
    hub_rg = constraints.get("networkResourceGroup")
    hub_space = constraints.get("vnetAddressSpace")

    lines = ["## Networking Topology", "", f"VNets discovered: {len(vnets)}", ""]
    if hub:
        lines.append(f"- **Hub VNet**: {hub} (resource group: {hub_rg or 'unknown'})")
        if hub_space:
            lines.append(f"- **Hub address space**: {hub_space}")
    else:
        lines.append("- **Hub VNet**: none identified")
    lines.append("")

    if vnets:
        lines.append("| Name | Address Space | Peerings | Resource Group |")
        lines.append("|---|---|---|---|")
        for vnet in vnets:
            address_space = vnet.get("addressSpace")
            if isinstance(address_space, list):
                address_space = ", ".join(address_space)
            peerings = vnet.get("peerings") or []
            lines.append(
                f"| {vnet.get('name', '')} | {address_space or ''} | {len(peerings)} | "
                f"{vnet.get('resourceGroup', '')} |"
            )
    return "\n".join(lines) + "\n"


def render_policy(data):
    if "policy" not in data:
        return section_unavailable("Policy Constraints")
    policy = data["policy"] or {}
    deny_modify = policy.get("relevantDenyOrModify") or []
    constraints = data.get("architectureConstraints") or {}
    required_tags = constraints.get("requiredTags") or []

    lines = ["## Policy Constraints", "", f"Deny/Modify policies: {len(deny_modify)}"]
    if required_tags:
        lines.append(f"- **Required tags** (from policy): {', '.join(required_tags)}")
    else:
        lines.append("- **Required tags** (from policy): none identified")
    lines.append("")

    if deny_modify:
        lines.append("| Definition | Effect |")
        lines.append("|---|---|")
        for entry in deny_modify:
            lines.append(
                f"| {entry.get('definitionName', '')} | {entry.get('effect', '')} |"
            )
    return "\n".join(lines) + "\n"


def render_rbac(data):
    if "rbac" not in data:
        return section_unavailable("RBAC Ownership")
    rbac = data["rbac"] or {}
    assignments = rbac.get("assignments") or []
    custom_roles = rbac.get("customRoles") or []
    ownership = rbac.get("ownershipSummary") or {}

    lines = [
        "## RBAC Ownership",
        "",
        f"Total assignments: {len(assignments)}",
        f"Custom roles: {len(custom_roles)}",
        "",
    ]
    if ownership:
        lines.append("| Role | Assignment Count |")
        lines.append("|---|---|")
        for role, count in sorted(ownership.items(), key=lambda kv: kv[0]):
            lines.append(f"| {role} | {count} |")
    return "\n".join(lines) + "\n"


def render_providers(data):
    if "providers" not in data:
        return section_unavailable("Resource Provider Registration")
    providers = data["providers"] or []
    lines = ["## Resource Provider Registration", "", "| Namespace | State |", "|---|---|"]
    for provider in providers:
        lines.append(
            f"| {provider.get('namespace', '')} | {provider.get('registrationState', '')} |"
        )
    return "\n".join(lines) + "\n"


def render_private_endpoints_dns(data):
    if "privateEndpoints" not in data and "privateDns" not in data:
        return section_unavailable("Private Endpoints & DNS")

    lines = ["## Private Endpoints & DNS", ""]

    if "privateEndpoints" in data:
        endpoints = data["privateEndpoints"] or []
        lines.append(f"Private endpoints: {len(endpoints)}")
    else:
        lines.append("Private endpoints: not available in this discovery output")

    if "privateDns" in data:
        zones = data["privateDns"] or []
        unlinked = [z for z in zones if not (z.get("linkedVnets") or [])]
        lines.append(f"Private DNS zones: {len(zones)} ({len(unlinked)} with no linked VNets)")
        if unlinked:
            lines.append("")
            lines.append("Zones with no linked VNets:")
            for zone in unlinked:
                lines.append(f"- {zone.get('name', '')}")
    else:
        lines.append("Private DNS zones: not available in this discovery output")

    return "\n".join(lines) + "\n"


def render_quotas(data):
    if "quotas" not in data:
        return section_unavailable("Quota Headroom")
    quotas = data["quotas"] or []
    by_region = {}
    for quota in quotas:
        by_region.setdefault(quota.get("region", "unknown"), []).append(quota)

    lines = ["## Quota Headroom", "", f"Total quota entries: {len(quotas)}", ""]
    for region in sorted(by_region):
        lines.append(f"### {region}")
        lines.append("")
        lines.append(f"{len(by_region[region])} quota entries tracked.")
        lines.append("")
    return "\n".join(lines) + "\n"


def _quota_usage_ratio(quota):
    try:
        current = float(quota.get("currentValue"))
        limit = float(quota.get("limit"))
    except (TypeError, ValueError):
        return None
    if limit <= 0:
        return None
    return current / limit


def find_risks(data, quota_threshold):
    risks = []

    providers = data.get("providers") or []
    for provider in providers:
        state = provider.get("registrationState")
        if state != "Registered":
            risks.append(
                f"Provider `{provider.get('namespace', '')}` is not registered "
                f"(state: {state})"
            )

    quotas = data.get("quotas") or []
    for quota in quotas:
        ratio = _quota_usage_ratio(quota)
        if ratio is not None and ratio >= quota_threshold:
            risks.append(
                f"Quota `{quota.get('name', '')}` in `{quota.get('region', '')}` is at "
                f"{ratio:.0%} usage ({quota.get('currentValue', '')}/{quota.get('limit', '')})"
            )

    constraints = data.get("architectureConstraints") or {}
    if "hubPeering" in constraints and constraints.get("hubPeering") is None:
        risks.append("No hub VNet was identified from the discovered networking topology")

    return risks


def render_risks(data, quota_threshold):
    risks = find_risks(data, quota_threshold)
    lines = ["## Readiness Risks & Gaps", ""]
    if not risks:
        lines.append("No risks found.")
    else:
        for risk in risks:
            lines.append(f"- {risk}")
    return "\n".join(lines) + "\n"


def render_report(data, quota_threshold):
    sections = [
        render_meta(data),
        render_risks(data, quota_threshold),
        render_resource_groups(data),
        render_networking(data),
        render_policy(data),
        render_rbac(data),
        render_providers(data),
        render_private_endpoints_dns(data),
        render_quotas(data),
    ]
    return "# Architecture Readiness Report\n\n" + "\n".join(sections)


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    data = load_discovery_json(args.input)
    report = render_report(data, args.quota_threshold)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(report)
    else:
        sys.stdout.write(report)


if __name__ == "__main__":
    main()
