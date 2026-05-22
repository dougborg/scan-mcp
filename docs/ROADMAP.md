# Roadmap

This document collects ideas and future work for scan-mcp.

## Resource-based Document Access

Replace filesystem paths with MCP resource URIs (e.g., `mcp://scan-mcp/jobs/{job_id}/document/1`)
to enable tighter integration with document-processing pipelines. Other MCP servers could then
consume scanned documents via ReadMcpResourceTool without filesystem coupling, improving
portability, security, and composition.

## Real-time Job Progress Updates

Provide streaming progress for long-running jobs instead of polling. For large batches (100+ pages),
streaming would improve feedback for page-by-page progress, errors, and completion.

- Progress utility: https://modelcontextprotocol.io/specification/2025-03-26/basic/utilities/progress
- Cancellation utility (to supersede `cancel_job`):
  https://modelcontextprotocol.io/specification/2025-03-26/basic/utilities/cancellation

## Windows Backend

macOS (via ImageCaptureCore) and Linux (via SANE `scanimage`) are now both supported through the `Backend` interface in `src/services/backends/`. A Windows backend (likely via WIA — Windows Image Acquisition) is the remaining cross-platform gap.

