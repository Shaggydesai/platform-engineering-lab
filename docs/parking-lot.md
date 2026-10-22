# Parking lot

Problems deliberately deferred. Rule 2 of the roadmap: if a side problem has eaten 45 minutes, it
lands here and we route around it. Revisit when it blocks something real, not when it annoys you.

| Date | Problem | Why deferred | Workaround in use |
|:--|:--|:--|:--|
| 2026-10-22 | **Hubble Relay runs without TLS.** The chart warns about it on install: `hubble.relay.tls.server.enabled=false`, so flow data between the agents and the relay is unencrypted. | Enabling it means certificate management, and we have not decided how certificates are issued in this cluster yet — that is cert-manager's job, which arrives as a Layer 3 component. Doing it by hand now would create exactly the hand-made thing ADR-0002 Rule 3 exists to prevent. | Nothing. The cluster is on an isolated NAT network inside one laptop, and the only consumer of Hubble is `hubble observe` on the node. **Revisit in Module 10** when the Hubble UI is installed via Argo CD and the flow data leaves the node — and strictly before anything resembling real traffic exists. |
