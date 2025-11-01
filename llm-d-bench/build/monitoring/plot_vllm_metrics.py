#!/usr/bin/env python3
"""
vLLM Metrics Visualization Script

Transforms collected metrics CSV data and generates comprehensive plots
for vLLM performance analysis including throughput, latency, cache usage,
and node resource utilization.

Based on vLLM metrics documentation:
https://docs.vllm.ai/en/latest/design/metrics.html
"""

import pandas as pd
import plotly.graph_objects as go
from plotly.subplots import make_subplots
import argparse
import os
import sys
from typing import Optional, Dict


def load_metrics(csv_file: str) -> pd.DataFrame:
    """Load metrics from CSV file"""
    if not os.path.exists(csv_file):
        raise FileNotFoundError(f"Metrics file not found: {csv_file}")

    df = pd.read_csv(csv_file)

    # Convert timestamp to datetime
    df["datetime"] = pd.to_datetime(df["collection_time"])

    # Calculate relative time in seconds from start
    df["time_seconds"] = (df["datetime"] - df["datetime"].min()).dt.total_seconds()

    return df


def get_histogram_columns(df: pd.DataFrame, base_metric: str) -> Dict[str, str]:
    """
    Get histogram percentile columns for a metric.

    Args:
        df: DataFrame with metrics
        base_metric: Base metric name (e.g., "vllm:time_to_first_token_seconds")

    Returns:
        Dictionary mapping percentile labels to column names
    """
    columns = {}
    for col in df.columns:
        if col.startswith(f"{base_metric}:"):
            # Extract percentile label (e.g., "p50", "p95", "avg")
            label = col.split(":", 1)[1]
            columns[label] = col
    return columns


def calculate_derived_metrics(df: pd.DataFrame) -> pd.DataFrame:
    """Calculate derived metrics from raw data"""

    # Calculate cache hit rates if applicable
    if (
        "vllm:prompt_tokens_total" in df.columns
        and "vllm:generation_tokens_total" in df.columns
    ):
        df["total_tokens"] = (
            df["vllm:prompt_tokens_total"] + df["vllm:generation_tokens_total"]
        )

    # Calculate network throughput in MB/s
    if "node_network_transmit_bytes_per_sec" in df.columns:
        df["network_tx_mbps"] = df["node_network_transmit_bytes_per_sec"] / (
            1024 * 1024
        )
    if "node_network_receive_bytes_per_sec" in df.columns:
        df["network_rx_mbps"] = df["node_network_receive_bytes_per_sec"] / (1024 * 1024)

    # Calculate memory in GB
    if "node_memory_used_bytes" in df.columns:
        df["memory_used_gb"] = df["node_memory_used_bytes"] / (1024**3)
    if "node_memory_available_bytes" in df.columns:
        df["memory_available_gb"] = df["node_memory_available_bytes"] / (1024**3)

    # Calculate disk usage in GB
    if "node_disk_used_bytes" in df.columns:
        df["disk_used_gb"] = df["node_disk_used_bytes"] / (1024**3)

    return df


def plot_comprehensive_metrics(
    df: pd.DataFrame, output_file: str, title_prefix: str = ""
):
    """Create comprehensive multi-panel visualization of all metrics"""

    # Determine which metrics are available
    has_vllm = any(col.startswith("vllm:") for col in df.columns)
    has_node = any(col.startswith("node_") for col in df.columns)

    # Create subplots based on available data
    subplot_titles = []
    rows = 0

    if has_vllm:
        subplot_titles.extend(
            [
                "Request Queue Depth",
                "Cache Usage",
                "Token Throughput",
                "Latency Metrics (TTFT, TPOT, E2E, ITL)",
                "Request Timing (Prefill, Decode, Queue)",
            ]
        )
        rows += 5

    if has_node:
        subplot_titles.extend(["CPU & Memory Usage", "Network Throughput", "Disk I/O"])
        rows += 3

    fig = make_subplots(
        rows=rows,
        cols=1,
        subplot_titles=subplot_titles,
        vertical_spacing=0.05,
        row_heights=[1] * rows,
    )

    current_row = 1

    # vLLM Metrics Plots
    if has_vllm:
        # 1. Request Queue Metrics
        if "vllm:num_requests_running" in df.columns:
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["vllm:num_requests_running"],
                    name="Running Requests",
                    mode="lines",
                    line=dict(color="green"),
                ),
                row=current_row,
                col=1,
            )
        if "vllm:num_requests_waiting" in df.columns:
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["vllm:num_requests_waiting"],
                    name="Waiting Requests",
                    mode="lines",
                    line=dict(color="orange"),
                ),
                row=current_row,
                col=1,
            )
        if "vllm:num_requests_swapped" in df.columns:
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["vllm:num_requests_swapped"],
                    name="Swapped Requests",
                    mode="lines",
                    line=dict(color="red"),
                ),
                row=current_row,
                col=1,
            )
        fig.update_yaxes(title_text="Request Count", row=current_row, col=1)
        current_row += 1

        # 2. Cache Usage
        if "vllm:kv_cache_usage_perc" in df.columns:
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["vllm:kv_cache_usage_perc"],
                    name="KV Cache Usage %",
                    mode="lines",
                    line=dict(color="purple"),
                ),
                row=current_row,
                col=1,
            )
        fig.update_yaxes(title_text="Cache Usage (%)", row=current_row, col=1)
        current_row += 1

        # 3. Token Rates (Counter rates - derived from totals)
        if "vllm:prompt_tokens_total" in df.columns:
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["vllm:prompt_tokens_total"],
                    name="Prompt Token Rate",
                    mode="lines",
                    line=dict(color="cyan"),
                ),
                row=current_row,
                col=1,
            )
        if "vllm:generation_tokens_total" in df.columns:
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["vllm:generation_tokens_total"],
                    name="Generation Token Rate",
                    mode="lines",
                    line=dict(color="magenta"),
                ),
                row=current_row,
                col=1,
            )
        fig.update_yaxes(title_text="Tokens/Second (rate)", row=current_row, col=1)
        current_row += 1

        # 4. Latency Metrics (Histograms with percentiles)
        # Time to First Token
        ttft_cols = get_histogram_columns(df, "vllm:time_to_first_token_seconds")
        if ttft_cols:
            colors = {
                "avg": "red",
                "p50": "orange",
                "p90": "yellow",
                "p95": "pink",
                "p99": "darkred",
            }
            for label, col in sorted(ttft_cols.items()):
                # Make p50 (median) thicker and more prominent
                line_width = 3 if label == "p50" else 1.5 if label == "avg" else 1
                fig.add_trace(
                    go.Scatter(
                        x=df["time_seconds"],
                        y=df[col],
                        name=f"TTFT {label.upper()}"
                        + (" (median)" if label == "p50" else ""),
                        mode="lines",
                        line=dict(
                            color=colors.get(label, "red"),
                            width=line_width,
                            dash="solid" if label in ["p50", "avg"] else "dash",
                        ),
                    ),
                    row=current_row,
                    col=1,
                )
        elif "vllm:time_to_first_token_seconds" in df.columns:
            # Fallback for old format
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["vllm:time_to_first_token_seconds"],
                    name="Time to First Token",
                    mode="lines",
                    line=dict(color="red"),
                ),
                row=current_row,
                col=1,
            )

        # Time per Output Token
        tpot_cols = get_histogram_columns(df, "vllm:time_per_output_token_seconds")
        if tpot_cols:
            colors = {
                "avg": "blue",
                "p50": "cyan",
                "p90": "lightblue",
                "p95": "steelblue",
                "p99": "darkblue",
            }
            for label, col in sorted(tpot_cols.items()):
                line_width = 3 if label == "p50" else 1.5 if label == "avg" else 1
                fig.add_trace(
                    go.Scatter(
                        x=df["time_seconds"],
                        y=df[col],
                        name=f"TPOT {label.upper()}"
                        + (" (median)" if label == "p50" else ""),
                        mode="lines",
                        line=dict(
                            color=colors.get(label, "blue"),
                            width=line_width,
                            dash="solid" if label in ["p50", "avg"] else "dash",
                        ),
                    ),
                    row=current_row,
                    col=1,
                )
        elif "vllm:time_per_output_token_seconds" in df.columns:
            # Fallback for old format
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["vllm:time_per_output_token_seconds"],
                    name="Time per Output Token",
                    mode="lines",
                    line=dict(color="orange"),
                ),
                row=current_row,
                col=1,
            )

        # E2E Request Latency
        e2e_cols = get_histogram_columns(df, "vllm:e2e_request_latency_seconds")
        if e2e_cols:
            colors = {
                "avg": "green",
                "p50": "lime",
                "p90": "lightgreen",
                "p95": "forestgreen",
                "p99": "darkgreen",
            }
            for label, col in sorted(e2e_cols.items()):
                line_width = 3 if label == "p50" else 1.5 if label == "avg" else 1
                fig.add_trace(
                    go.Scatter(
                        x=df["time_seconds"],
                        y=df[col],
                        name=f"E2E {label.upper()}"
                        + (" (median)" if label == "p50" else ""),
                        mode="lines",
                        line=dict(
                            color=colors.get(label, "green"),
                            width=line_width,
                            dash="solid" if label in ["p50", "avg"] else "dash",
                        ),
                    ),
                    row=current_row,
                    col=1,
                )
        elif "vllm:e2e_request_latency_seconds" in df.columns:
            # Fallback for old format
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["vllm:e2e_request_latency_seconds"],
                    name="E2E Latency",
                    mode="lines",
                    line=dict(color="yellow"),
                ),
                row=current_row,
                col=1,
            )

        # Inter-token Latency
        itl_cols = get_histogram_columns(df, "vllm:inter_token_latency_seconds")
        if itl_cols:
            colors = {
                "avg": "purple",
                "p50": "magenta",
                "p90": "violet",
                "p95": "darkviolet",
                "p99": "indigo",
            }
            for label, col in sorted(itl_cols.items()):
                line_width = 3 if label == "p50" else 1.5 if label == "avg" else 1
                fig.add_trace(
                    go.Scatter(
                        x=df["time_seconds"],
                        y=df[col],
                        name=f"ITL {label.upper()}"
                        + (" (median)" if label == "p50" else ""),
                        mode="lines",
                        line=dict(
                            color=colors.get(label, "purple"),
                            width=line_width,
                            dash="solid" if label in ["p50", "avg"] else "dash",
                        ),
                    ),
                    row=current_row,
                    col=1,
                )

        fig.update_yaxes(title_text="Latency (seconds)", row=current_row, col=1)
        current_row += 1

        # 5. Request Timing Metrics (Prefill, Decode, Queue)
        # Prefill Time
        prefill_cols = get_histogram_columns(df, "vllm:request_prefill_time_seconds")
        if prefill_cols:
            colors = {
                "avg": "orange",
                "p50": "gold",
                "p90": "yellow",
                "p95": "darkorange",
                "p99": "orangered",
            }
            for label, col in sorted(prefill_cols.items()):
                line_width = 3 if label == "p50" else 1.5 if label == "avg" else 1
                fig.add_trace(
                    go.Scatter(
                        x=df["time_seconds"],
                        y=df[col],
                        name=f"Prefill {label.upper()}"
                        + (" (median)" if label == "p50" else ""),
                        mode="lines",
                        line=dict(
                            color=colors.get(label, "orange"),
                            width=line_width,
                            dash="solid" if label in ["p50", "avg"] else "dash",
                        ),
                    ),
                    row=current_row,
                    col=1,
                )

        # Decode Time
        decode_cols = get_histogram_columns(df, "vllm:request_decode_time_seconds")
        if decode_cols:
            colors = {
                "avg": "teal",
                "p50": "turquoise",
                "p90": "lightseagreen",
                "p95": "darkcyan",
                "p99": "darkslategray",
            }
            for label, col in sorted(decode_cols.items()):
                line_width = 3 if label == "p50" else 1.5 if label == "avg" else 1
                fig.add_trace(
                    go.Scatter(
                        x=df["time_seconds"],
                        y=df[col],
                        name=f"Decode {label.upper()}"
                        + (" (median)" if label == "p50" else ""),
                        mode="lines",
                        line=dict(
                            color=colors.get(label, "teal"),
                            width=line_width,
                            dash="solid" if label in ["p50", "avg"] else "dash",
                        ),
                    ),
                    row=current_row,
                    col=1,
                )

        # Queue Time
        queue_cols = get_histogram_columns(df, "vllm:request_queue_time_seconds")
        if queue_cols:
            colors = {
                "avg": "brown",
                "p50": "coral",
                "p90": "salmon",
                "p95": "sienna",
                "p99": "maroon",
            }
            for label, col in sorted(queue_cols.items()):
                line_width = 3 if label == "p50" else 1.5 if label == "avg" else 1
                fig.add_trace(
                    go.Scatter(
                        x=df["time_seconds"],
                        y=df[col],
                        name=f"Queue {label.upper()}"
                        + (" (median)" if label == "p50" else ""),
                        mode="lines",
                        line=dict(
                            color=colors.get(label, "brown"),
                            width=line_width,
                            dash="solid" if label in ["p50", "avg"] else "dash",
                        ),
                    ),
                    row=current_row,
                    col=1,
                )

        fig.update_yaxes(title_text="Time (seconds)", row=current_row, col=1)
        current_row += 1

    # Node Metrics Plots
    if has_node:
        # 6. CPU and Memory
        if "node_cpu_percent" in df.columns:
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["node_cpu_percent"],
                    name="CPU Usage %",
                    mode="lines",
                    line=dict(color="blue"),
                ),
                row=current_row,
                col=1,
            )
        if "node_memory_percent" in df.columns:
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["node_memory_percent"],
                    name="Memory Usage %",
                    mode="lines",
                    line=dict(color="green"),
                ),
                row=current_row,
                col=1,
            )
        fig.update_yaxes(title_text="Usage (%)", row=current_row, col=1)
        current_row += 1

        # 6. Network Throughput
        if "network_tx_mbps" in df.columns:
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["network_tx_mbps"],
                    name="Network TX",
                    mode="lines",
                    line=dict(color="orange"),
                ),
                row=current_row,
                col=1,
            )
        if "network_rx_mbps" in df.columns:
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["network_rx_mbps"],
                    name="Network RX",
                    mode="lines",
                    line=dict(color="purple"),
                ),
                row=current_row,
                col=1,
            )
        fig.update_yaxes(title_text="MB/second", row=current_row, col=1)
        current_row += 1

        # 7. Disk I/O
        if "node_disk_read_bytes_total" in df.columns:
            # Calculate disk I/O rate (derivative)
            df["disk_read_rate"] = (
                df["node_disk_read_bytes_total"].diff()
                / df["time_seconds"].diff()
                / (1024**2)
            )
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["disk_read_rate"],
                    name="Disk Read",
                    mode="lines",
                    line=dict(color="cyan"),
                ),
                row=current_row,
                col=1,
            )
        if "node_disk_write_bytes_total" in df.columns:
            df["disk_write_rate"] = (
                df["node_disk_write_bytes_total"].diff()
                / df["time_seconds"].diff()
                / (1024**2)
            )
            fig.add_trace(
                go.Scatter(
                    x=df["time_seconds"],
                    y=df["disk_write_rate"],
                    name="Disk Write",
                    mode="lines",
                    line=dict(color="magenta"),
                ),
                row=current_row,
                col=1,
            )
        fig.update_yaxes(title_text="MB/second", row=current_row, col=1)

    # Update layout
    fig.update_layout(
        height=300 * rows,
        title_text=f"{title_prefix}vLLM Benchmark Metrics Dashboard"
        if title_prefix
        else "vLLM Benchmark Metrics Dashboard",
        showlegend=True,
        template="plotly_dark",
    )

    # Update all x-axes
    for i in range(1, rows + 1):
        fig.update_xaxes(title_text="Time (seconds)" if i == rows else "", row=i, col=1)

    # Save to HTML
    fig.write_html(output_file)
    print(f"Comprehensive metrics dashboard saved to: {output_file}")


def plot_summary_statistics(df: pd.DataFrame, output_file: str):
    """Create summary statistics table and box plots"""

    # Select key metrics for summary (including histogram percentiles)
    key_metric_patterns = [
        "vllm:time_to_first_token_seconds",
        "vllm:time_per_output_token_seconds",
        "vllm:e2e_request_latency_seconds",
        "vllm:inter_token_latency_seconds",
        "vllm:request_prefill_time_seconds",
        "vllm:request_decode_time_seconds",
        "vllm:request_queue_time_seconds",
        "vllm:kv_cache_usage_perc",
        "vllm:num_requests_running",
        "vllm:num_requests_waiting",
        "node_cpu_percent",
        "node_memory_percent",
    ]

    # Find available metrics (including histogram variants)
    available_metrics = []
    for pattern in key_metric_patterns:
        # Check for exact match
        if pattern in df.columns:
            available_metrics.append(pattern)
        # Check for histogram percentile columns
        for col in df.columns:
            if col.startswith(f"{pattern}:"):
                available_metrics.append(col)

    if not available_metrics:
        print("No key metrics available for summary statistics")
        return

    # Calculate statistics
    stats_data = []
    for metric in available_metrics:
        data = df[metric].dropna()
        if len(data) > 0:
            # Clean metric name for display
            display_name = (
                metric.replace("vllm:", "").replace("node_", "").replace(":", " ")
            )
            stats_data.append(
                {
                    "Metric": display_name,
                    "Mean": f"{data.mean():.4f}",
                    "Median": f"{data.median():.4f}",
                    "Min": f"{data.min():.4f}",
                    "Max": f"{data.max():.4f}",
                    "Std Dev": f"{data.std():.4f}",
                    "P95": f"{data.quantile(0.95):.4f}",
                    "P99": f"{data.quantile(0.99):.4f}",
                }
            )

    # Create table figure
    stats_df = pd.DataFrame(stats_data)

    fig = go.Figure(
        data=[
            go.Table(
                header=dict(
                    values=list(stats_df.columns),
                    fill_color="paleturquoise",
                    align="left",
                    font=dict(size=12, color="black"),
                ),
                cells=dict(
                    values=[stats_df[col] for col in stats_df.columns],
                    fill_color="lavender",
                    align="left",
                    font=dict(size=11, color="black"),
                ),
            )
        ]
    )

    fig.update_layout(title="vLLM Metrics Summary Statistics", height=400)

    fig.write_html(output_file)
    print(f"Summary statistics saved to: {output_file}")


def main():
    parser = argparse.ArgumentParser(
        description="Visualize vLLM benchmark metrics from CSV file"
    )
    parser.add_argument("csv_file", help="Path to metrics CSV file")
    parser.add_argument(
        "--output-dir",
        help="Output directory for plots (default: same as CSV file)",
        default=None,
    )
    parser.add_argument("--title-prefix", help="Prefix for plot titles", default="")

    args = parser.parse_args()

    # Determine output directory
    if args.output_dir:
        output_dir = args.output_dir
    else:
        output_dir = os.path.dirname(args.csv_file)

    os.makedirs(output_dir, exist_ok=True)

    # Base filename for outputs
    base_name = os.path.splitext(os.path.basename(args.csv_file))[0]

    try:
        print(f"Loading metrics from: {args.csv_file}")
        df = load_metrics(args.csv_file)
        print(f"Loaded {len(df)} data points")

        print("Calculating derived metrics...")
        df = calculate_derived_metrics(df)

        print("Generating comprehensive dashboard...")
        dashboard_file = os.path.join(output_dir, f"{base_name}_dashboard.html")
        plot_comprehensive_metrics(df, dashboard_file, args.title_prefix)

        print("Generating summary statistics...")
        summary_file = os.path.join(output_dir, f"{base_name}_summary.html")
        plot_summary_statistics(df, summary_file)

        print("\nVisualization complete!")
        print(f"Dashboard: {dashboard_file}")
        print(f"Summary: {summary_file}")

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
