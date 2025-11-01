#!/usr/bin/env python3
import os
import sys
import time
import json
import csv
import requests
import urllib3
import argparse
import signal
import logging
import psutil

from datetime import datetime
from typing import Dict, List, Optional, Any
from enum import Enum
from dataclasses import dataclass

# Disable SSL warnings for internal cluster services
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


class MetricType(Enum):
    """Prometheus metric types used by vLLM"""

    COUNTER = "counter"  # Monotonically increasing
    GAUGE = "gauge"  # Can go up or down
    HISTOGRAM = "histogram"  # Distribution with buckets


@dataclass
class MetricConfig:
    """Configuration for a specific metric"""

    name: str
    type: MetricType
    description: str
    unit: Optional[str] = None
    # For histograms, define percentiles to extract
    percentiles: Optional[List[float]] = None


# vLLM Metrics Classification
# Based on vLLM documentation and Prometheus naming conventions
VLLM_METRICS_CONFIG: Dict[str, MetricConfig] = {
    # === GAUGE METRICS ===
    # Request queue metrics (point-in-time snapshots)
    "vllm:num_requests_running": MetricConfig(
        name="vllm:num_requests_running",
        type=MetricType.GAUGE,
        description="Number of requests currently being processed",
        unit="requests",
    ),
    "vllm:num_requests_waiting": MetricConfig(
        name="vllm:num_requests_waiting",
        type=MetricType.GAUGE,
        description="Number of requests waiting in queue",
        unit="requests",
    ),
    # Cache usage metrics (point-in-time percentages)
    "vllm:kv_cache_usage_perc": MetricConfig(
        name="vllm:kv_cache_usage_perc",
        type=MetricType.GAUGE,
        description="KV cache usage percentage",
        unit="percent",
    ),
    # === COUNTER METRICS ===
    # Token counters (monotonically increasing totals)
    "vllm:prompt_tokens_total": MetricConfig(
        name="vllm:prompt_tokens_total",
        type=MetricType.COUNTER,
        description="Total number of prompt tokens processed",
        unit="tokens",
    ),
    "vllm:generation_tokens_total": MetricConfig(
        name="vllm:generation_tokens_total",
        type=MetricType.COUNTER,
        description="Total number of tokens generated",
        unit="tokens",
    ),
    "vllm:num_preemptions_total": MetricConfig(
        name="vllm:num_preemptions_total",
        type=MetricType.COUNTER,
        description="Total number of preemptions",
        unit="count",
    ),
    "vllm:request_success_total": MetricConfig(
        name="vllm:request_success_total",
        type=MetricType.COUNTER,
        description="Total number of successful requests",
        unit="requests",
    ),
    # === HISTOGRAM METRICS ===
    # Latency distributions (require percentile extraction)
    "vllm:time_to_first_token_seconds": MetricConfig(
        name="vllm:time_to_first_token_seconds",
        type=MetricType.HISTOGRAM,
        description="Time to first token (TTFT) distribution",
        unit="seconds",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    "vllm:time_per_output_token_seconds": MetricConfig(
        name="vllm:time_per_output_token_seconds",
        type=MetricType.HISTOGRAM,
        description="Time per output token (TPOT) distribution",
        unit="seconds",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    "vllm:e2e_request_latency_seconds": MetricConfig(
        name="vllm:e2e_request_latency_seconds",
        type=MetricType.HISTOGRAM,
        description="End-to-end request latency distribution",
        unit="seconds",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    "vllm:inter_token_latency_seconds": MetricConfig(
        name="vllm:inter_token_latency_seconds",
        type=MetricType.HISTOGRAM,
        description="Inter-token latency distribution",
        unit="seconds",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    # Request timing histograms
    "vllm:request_prefill_time_seconds": MetricConfig(
        name="vllm:request_prefill_time_seconds",
        type=MetricType.HISTOGRAM,
        description="Request prefill (prompt processing) time",
        unit="seconds",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    "vllm:request_decode_time_seconds": MetricConfig(
        name="vllm:request_decode_time_seconds",
        type=MetricType.HISTOGRAM,
        description="Request decode (generation) time",
        unit="seconds",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    "vllm:request_queue_time_seconds": MetricConfig(
        name="vllm:request_queue_time_seconds",
        type=MetricType.HISTOGRAM,
        description="Time requests spend in queue",
        unit="seconds",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    # Prefix cache counters
    "vllm:prefix_cache_hits_total": MetricConfig(
        name="vllm:prefix_cache_hits_total",
        type=MetricType.COUNTER,
        description="Total number of prefix cache hits",
        unit="count",
    ),
    "vllm:prefix_cache_queries_total": MetricConfig(
        name="vllm:prefix_cache_queries_total",
        type=MetricType.COUNTER,
        description="Total number of prefix cache queries",
        unit="count",
    ),
    # Info/configuration metrics
    "vllm:cache_config_info": MetricConfig(
        name="vllm:cache_config_info",
        type=MetricType.GAUGE,
        description="Cache configuration information",
        unit="info",
    ),
    # Iteration tokens histogram
    "vllm:iteration_tokens_total": MetricConfig(
        name="vllm:iteration_tokens_total",
        type=MetricType.HISTOGRAM,
        description="Total tokens per iteration distribution",
        unit="tokens",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    # Request token histograms
    "vllm:request_generation_tokens": MetricConfig(
        name="vllm:request_generation_tokens",
        type=MetricType.HISTOGRAM,
        description="Number of tokens generated per request",
        unit="tokens",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    "vllm:request_prompt_tokens": MetricConfig(
        name="vllm:request_prompt_tokens",
        type=MetricType.HISTOGRAM,
        description="Number of prompt tokens per request",
        unit="tokens",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    # Additional timing histograms
    "vllm:request_inference_time_seconds": MetricConfig(
        name="vllm:request_inference_time_seconds",
        type=MetricType.HISTOGRAM,
        description="Total inference time per request",
        unit="seconds",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    "vllm:request_time_per_output_token_seconds": MetricConfig(
        name="vllm:request_time_per_output_token_seconds",
        type=MetricType.HISTOGRAM,
        description="Time per output token per request",
        unit="seconds",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    # Request parameter histograms
    "vllm:request_max_num_generation_tokens": MetricConfig(
        name="vllm:request_max_num_generation_tokens",
        type=MetricType.HISTOGRAM,
        description="Maximum number of generation tokens requested",
        unit="tokens",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    "vllm:request_params_max_tokens": MetricConfig(
        name="vllm:request_params_max_tokens",
        type=MetricType.HISTOGRAM,
        description="max_tokens parameter value per request",
        unit="tokens",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
    "vllm:request_params_n": MetricConfig(
        name="vllm:request_params_n",
        type=MetricType.HISTOGRAM,
        description="n parameter value per request (number of completions)",
        unit="count",
        percentiles=[0.5, 0.9, 0.95, 0.99],
    ),
}


class MetricQueryBuilder:
    """
    Builds appropriate PromQL queries based on metric type.

    Different metric types require different query strategies:
    - Counters: Use rate() for per-second rate
    - Gauges: Direct query for instant value
    - Histograms: Use histogram_quantile() for percentiles
    """

    @staticmethod
    def build_query(
        metric_name: str,
        metric_type: MetricType,
        labels: Optional[Dict[str, str]] = None,
        rate_interval: str = "1m",
        percentile: Optional[float] = None,
    ) -> str:
        """
        Build PromQL query for a metric based on its type.

        Args:
            metric_name: Name of the metric
            metric_type: Type of metric (Counter, Gauge, Histogram)
            labels: Optional label filters
            rate_interval: Time window for rate calculations (default: 1m)
            percentile: For histograms, which percentile to extract (0.0-1.0)

        Returns:
            PromQL query string
        """
        # Build label selector
        label_selector = ""
        if labels:
            label_filters = ",".join([f'{k}="{v}"' for k, v in labels.items()])
            label_selector = f"{{{label_filters}}}"

        if metric_type == MetricType.GAUGE:
            # Gauges: direct query for instant value
            return f"{metric_name}{label_selector}"

        elif metric_type == MetricType.COUNTER:
            # Counters: calculate rate over time window
            # Using rate() which handles counter resets
            return f"rate({metric_name}{label_selector}[{rate_interval}])"

        elif metric_type == MetricType.HISTOGRAM:
            if percentile is None:
                # If no percentile specified, query the _sum and _count for average
                # This is useful for basic timeseries visualization
                return f"rate({metric_name}_sum{label_selector}[{rate_interval}]) / rate({metric_name}_count{label_selector}[{rate_interval}])"
            else:
                # Extract specific percentile from histogram buckets
                # histogram_quantile requires le label (bucket boundaries)
                return f"histogram_quantile({percentile}, rate({metric_name}_bucket{label_selector}[{rate_interval}]))"

        else:
            raise ValueError(f"Unknown metric type: {metric_type}")

    @staticmethod
    def build_histogram_queries(
        metric_name: str,
        percentiles: List[float],
        labels: Optional[Dict[str, str]] = None,
        rate_interval: str = "1m",
    ) -> Dict[str, str]:
        """
        Build multiple queries for histogram percentiles.

        Args:
            metric_name: Name of the histogram metric
            percentiles: List of percentiles to extract (e.g., [0.5, 0.95, 0.99])
            labels: Optional label filters
            rate_interval: Time window for rate calculations

        Returns:
            Dictionary mapping percentile labels to PromQL queries
        """
        queries = {}

        # Add average query
        queries["avg"] = MetricQueryBuilder.build_query(
            metric_name, MetricType.HISTOGRAM, labels, rate_interval
        )

        # Add percentile queries
        for p in percentiles:
            label = f"p{int(p * 100)}"
            queries[label] = MetricQueryBuilder.build_query(
                metric_name, MetricType.HISTOGRAM, labels, rate_interval, percentile=p
            )

        return queries


def get_metric_config(metric_name: str) -> Optional[MetricConfig]:
    """Get configuration for a metric by name."""
    return VLLM_METRICS_CONFIG.get(metric_name)


def get_metrics_by_type(metric_type: MetricType) -> List[MetricConfig]:
    """Get all metrics of a specific type."""
    return [
        config for config in VLLM_METRICS_CONFIG.values() if config.type == metric_type
    ]


def infer_metric_type(metric_name: str) -> MetricType:
    """
    Infer metric type from name using Prometheus conventions.

    Heuristics:
    - Ends with _total -> Counter
    - Ends with _seconds/_milliseconds -> Histogram (latency metrics)
    - Contains _bucket/_sum/_count -> Histogram component
    - Default -> Gauge
    """
    # Check if we have explicit configuration
    config = get_metric_config(metric_name)
    if config:
        return config.type

    # Apply naming conventions
    name_lower = metric_name.lower()

    if "_total" in name_lower:
        return MetricType.COUNTER
    elif any(suffix in name_lower for suffix in ["_seconds", "_milliseconds"]):
        # Latency metrics are typically histograms
        return MetricType.HISTOGRAM
    elif any(suffix in name_lower for suffix in ["_bucket", "_sum", "_count"]):
        return MetricType.HISTOGRAM
    else:
        # Default to gauge for point-in-time metrics
        return MetricType.GAUGE


class MetricsCollector:
    """Collects vLLM metrics from Thanos Querier"""

    # Default vLLM metrics to collect
    # NOTE: These match actual vLLM metrics as of vLLM v0.6+
    # Verified against actual metric names from Prometheus
    DEFAULT_METRICS = [
        # Request queue metrics (Gauges)
        "vllm:num_requests_running",
        "vllm:num_requests_waiting",
        # KV cache usage (Gauge)
        "vllm:kv_cache_usage_perc",  # Note: not gpu_cache_usage_perc
        # Latency histograms
        "vllm:time_to_first_token_seconds",
        "vllm:time_per_output_token_seconds",
        "vllm:e2e_request_latency_seconds",
        "vllm:inter_token_latency_seconds",
        # Request timing histograms
        "vllm:request_prefill_time_seconds",
        "vllm:request_decode_time_seconds",
        "vllm:request_queue_time_seconds",
        # Token counters
        "vllm:prompt_tokens_total",
        "vllm:generation_tokens_total",
        "vllm:num_preemptions_total",
        "vllm:request_success_total",
        # Prefix cache metrics
        "vllm:prefix_cache_hits_total",
        "vllm:prefix_cache_queries_total",
    ]

    def __init__(
        self,
        thanos_url: str,
        output_dir: str,
        collection_interval: int = 1,
        metrics: Optional[List[str]] = None,
        labels: Optional[Dict[str, str]] = None,
        collect_node_metrics: bool = True,
        token_file: Optional[str] = None,
        rate_interval: str = "1m",
    ):
        """
        Initialize metrics collector

        Args:
            thanos_url: Thanos Querier endpoint URL
            output_dir: Directory to save metrics
            collection_interval: Seconds between collections
            metrics: List of metric names to collect (uses defaults if None)
            labels: Additional labels to filter metrics (e.g., {"model": "llama"})
            collect_node_metrics: Enable node-level metrics collection (CPU, memory, network)
            token_file: Path to ServiceAccount token file for authentication
            rate_interval: Time window for rate() calculations (default: 1m)
        """
        self.thanos_url = thanos_url.rstrip("/")
        self.output_dir = output_dir
        self.collection_interval = collection_interval

        # Filter out Prometheus internal metric components
        # These are handled automatically by histogram/counter queries
        raw_metrics = metrics or self.DEFAULT_METRICS
        self.metrics = self._filter_prometheus_components(raw_metrics)

        self.labels = labels or {}
        self.collect_node_metrics = collect_node_metrics
        self.rate_interval = rate_interval
        self.running = True

        # Read authentication token if provided
        self.token = None
        if token_file and os.path.exists(token_file):
            try:
                with open(token_file, "r") as f:
                    self.token = f.read().strip()
                logger.info(f"Loaded authentication token from {token_file}")
            except Exception as e:
                logger.warning(f"Failed to read token file {token_file}: {e}")

        # Create output directory
        os.makedirs(output_dir, exist_ok=True)

        # Initialize output files
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.csv_file = os.path.join(output_dir, f"metrics_{timestamp}.csv")
        self.json_file = os.path.join(output_dir, f"metrics_{timestamp}.json")
        self.all_metrics = []

        # Initialize network counters for delta calculations
        self.last_net_io = None
        self.last_net_time = None

        # Setup signal handlers for graceful shutdown
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)

        logger.info(f"Metrics collector initialized")
        logger.info(f"Thanos URL: {thanos_url}")
        logger.info(f"Output directory: {output_dir}")
        logger.info(f"Collection interval: {collection_interval}s")
        logger.info(f"Collecting {len(self.metrics)} vLLM metrics")
        logger.info(
            f"Node metrics collection: {'enabled' if collect_node_metrics else 'disabled'}"
        )

    def _signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully"""
        logger.info(f"Received signal {signum}, shutting down gracefully...")
        self.running = False

    def _filter_prometheus_components(self, metrics: List[str]) -> List[str]:
        """
        Filter out Prometheus internal metric components.

        These suffixes are automatically handled by the query builder:
        - _bucket: Histogram buckets (queried via histogram_quantile)
        - _sum: Histogram/Summary sum (queried via rate(_sum) / rate(_count))
        - _count: Histogram/Summary count (queried via rate(_count))
        - _created: Counter/Histogram creation timestamp (not useful for monitoring)

        Args:
            metrics: List of metric names

        Returns:
            Filtered list with base metric names only
        """
        filtered = []
        excluded_suffixes = ("_bucket", "_sum", "_count", "_created")

        for metric in metrics:
            if any(metric.endswith(suffix) for suffix in excluded_suffixes):
                # Extract base metric name
                base_metric = metric
                for suffix in excluded_suffixes:
                    if base_metric.endswith(suffix):
                        base_metric = base_metric[:-len(suffix)]
                        break

                # Only add base metric if not already in list
                if base_metric not in filtered:
                    filtered.append(base_metric)
                    logger.info(
                        f"Filtered Prometheus component '{metric}' -> using base metric '{base_metric}'"
                    )
            else:
                filtered.append(metric)

        return filtered

    def _build_queries_for_metric(self, metric_name: str) -> Dict[str, str]:
        """
        Build appropriate PromQL queries for a metric based on its type.

        Returns:
            Dictionary mapping query labels to PromQL query strings.
            For gauges and counters: {"value": "query"}
            For histograms: {"avg": "query", "p50": "query", "p95": "query", ...}
        """
        # Get metric configuration
        config = get_metric_config(metric_name)
        if not config:
            # Infer type from name if not in config
            metric_type = infer_metric_type(metric_name)
            logger.warning(
                f"Metric {metric_name} not in config, inferred type: {metric_type.value}"
            )
        else:
            metric_type = config.type

        # Build query based on type
        if metric_type == MetricType.HISTOGRAM:
            # For histograms, get percentiles
            percentiles = config.percentiles if config else [0.5, 0.95, 0.99]
            return MetricQueryBuilder.build_histogram_queries(
                metric_name, percentiles, self.labels, self.rate_interval
            )
        else:
            # For gauges and counters, single query
            query = MetricQueryBuilder.build_query(
                metric_name, metric_type, self.labels, self.rate_interval
            )
            return {"value": query}

    def _execute_promql_query(self, query: str) -> Optional[float]:
        """Execute a single PromQL query and return the value"""
        # Prepare headers with authentication token if available
        headers = {}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"

        try:
            response = requests.get(
                f"{self.thanos_url}/api/v1/query",
                params={"query": query},
                headers=headers,
                timeout=10,
                verify=False,  # Disable SSL verification for internal cluster services
            )
            response.raise_for_status()
            data = response.json()

            if data.get("status") != "success":
                error_msg = data.get("error", "Unknown error")
                logger.warning(f"Query failed: {error_msg}")
                logger.debug(f"Failed query was: {query}")
                return None

            results = data.get("data", {}).get("result", [])
            if not results:
                logger.debug(f"No data returned for query: {query}")
                return None

            # Handle multiple results by taking the first or aggregating
            # For most vLLM metrics, there should be a single result
            value = float(results[0]["value"][1])
            return value

        except requests.exceptions.RequestException as e:
            logger.warning(f"Error executing query: {e}")
            logger.debug(f"Failed query was: {query}")
            return None
        except (KeyError, ValueError, IndexError) as e:
            logger.warning(f"Error parsing query response: {e}")
            logger.debug(
                f"Query was: {query}, Response: {data if 'data' in locals() else 'N/A'}"
            )
            return None

    def _query_metric(self, metric_name: str) -> Dict[str, Any]:
        """
        Query a metric and return all relevant values based on metric type.

        Returns:
            Dictionary with metric values. Structure varies by type:
            - Gauge/Counter: {"value": float}
            - Histogram: {"avg": float, "p50": float, "p95": float, "p99": float}
        """
        queries = self._build_queries_for_metric(metric_name)
        results = {}

        logger.debug(f"Querying metric: {metric_name} with {len(queries)} queries")

        for label, query in queries.items():
            logger.debug(f"  [{label}] {query}")
            value = self._execute_promql_query(query)
            if value is not None:
                results[label] = value
                logger.debug(f"  [{label}] = {value}")
            else:
                results[label] = None
                logger.debug(f"  [{label}] = None (no data)")

        return results

    def _collect_node_metrics(self) -> Dict:
        """Collect node-level metrics (CPU, memory, network, disk)"""
        node_metrics = {}

        try:
            # CPU metrics
            cpu_percent = psutil.cpu_percent(interval=1, percpu=False)
            cpu_count = psutil.cpu_count()
            node_metrics["node_cpu_percent"] = cpu_percent
            node_metrics["node_cpu_count"] = cpu_count

            # Memory metrics
            mem = psutil.virtual_memory()
            node_metrics["node_memory_total_bytes"] = mem.total
            node_metrics["node_memory_available_bytes"] = mem.available
            node_metrics["node_memory_used_bytes"] = mem.used
            node_metrics["node_memory_percent"] = mem.percent

            # Network metrics (bytes/sec calculated as delta)
            current_net_io = psutil.net_io_counters()
            current_time = time.time()

            if self.last_net_io is not None and self.last_net_time is not None:
                time_delta = current_time - self.last_net_time
                bytes_sent_delta = (
                    current_net_io.bytes_sent - self.last_net_io.bytes_sent
                )
                bytes_recv_delta = (
                    current_net_io.bytes_recv - self.last_net_io.bytes_recv
                )

                node_metrics["node_network_transmit_bytes_per_sec"] = (
                    bytes_sent_delta / time_delta
                )
                node_metrics["node_network_receive_bytes_per_sec"] = (
                    bytes_recv_delta / time_delta
                )
            else:
                node_metrics["node_network_transmit_bytes_per_sec"] = 0
                node_metrics["node_network_receive_bytes_per_sec"] = 0

            # Update for next collection
            self.last_net_io = current_net_io
            self.last_net_time = current_time

            # Network totals
            node_metrics["node_network_transmit_bytes_total"] = (
                current_net_io.bytes_sent
            )
            node_metrics["node_network_receive_bytes_total"] = current_net_io.bytes_recv
            node_metrics["node_network_packets_sent_total"] = (
                current_net_io.packets_sent
            )
            node_metrics["node_network_packets_recv_total"] = (
                current_net_io.packets_recv
            )

            # Disk I/O metrics
            disk_io = psutil.disk_io_counters()
            if disk_io:
                node_metrics["node_disk_read_bytes_total"] = disk_io.read_bytes
                node_metrics["node_disk_write_bytes_total"] = disk_io.write_bytes
                node_metrics["node_disk_read_count_total"] = disk_io.read_count
                node_metrics["node_disk_write_count_total"] = disk_io.write_count

            # Disk usage for root
            disk_usage = psutil.disk_usage("/")
            node_metrics["node_disk_total_bytes"] = disk_usage.total
            node_metrics["node_disk_used_bytes"] = disk_usage.used
            node_metrics["node_disk_free_bytes"] = disk_usage.free
            node_metrics["node_disk_percent"] = disk_usage.percent

        except Exception as e:
            logger.error(f"Error collecting node metrics: {e}")

        return node_metrics

    def collect_metrics(self) -> Dict:
        """Collect all configured metrics"""
        collection_time = datetime.now()
        collection_timestamp = collection_time.timestamp()

        metrics_data = {
            "collection_time": collection_time.isoformat(),
            "collection_timestamp": collection_timestamp,
            "metrics": {},
        }

        # Collect vLLM metrics from Thanos
        for metric_name in self.metrics:
            result = self._query_metric(metric_name)

            # Determine metric type for metadata
            config = get_metric_config(metric_name)
            metric_type = (
                config.type.value if config else infer_metric_type(metric_name).value
            )

            # Store results with type information
            if result:
                # For histograms, we get multiple values (avg, p50, p95, etc.)
                # For gauges/counters, we get a single value
                if len(result) == 1 and "value" in result:
                    # Simple gauge/counter
                    metrics_data["metrics"][metric_name] = {
                        "value": result["value"],
                        "type": metric_type,
                    }
                else:
                    # Histogram with multiple percentiles
                    metrics_data["metrics"][metric_name] = {
                        **result,
                        "type": metric_type,
                    }
            else:
                metrics_data["metrics"][metric_name] = {
                    "value": None,
                    "type": metric_type,
                }

        # Collect node metrics if enabled
        if self.collect_node_metrics:
            node_metrics = self._collect_node_metrics()
            for metric_name, value in node_metrics.items():
                metrics_data["metrics"][metric_name] = {
                    "value": value,
                    "type": "gauge",  # Node metrics are all gauges
                }

        return metrics_data

    def _get_all_metric_columns(self, metrics_data: Dict) -> List[str]:
        """
        Extract all column names from metrics data.
        Handles both simple metrics (value) and histograms (avg, p50, p95, etc.)
        """
        columns = []
        for metric_name, metric_info in sorted(metrics_data["metrics"].items()):
            if "value" in metric_info and isinstance(
                metric_info["value"], (int, float, type(None))
            ):
                # Simple metric with single value
                columns.append(metric_name)
            else:
                # Histogram with multiple values
                for key in sorted(metric_info.keys()):
                    if key != "type" and isinstance(
                        metric_info.get(key), (int, float, type(None))
                    ):
                        columns.append(f"{metric_name}:{key}")
        return columns

    def _write_csv_header(self, all_metric_columns: List[str]):
        """Write CSV header with all metric column names"""
        with open(self.csv_file, "w", newline="") as f:
            writer = csv.writer(f)
            header = ["timestamp", "collection_time"] + all_metric_columns
            writer.writerow(header)

    def _append_to_csv(self, metrics_data: Dict, all_metric_columns: List[str]):
        """Append metrics to CSV file"""
        with open(self.csv_file, "a", newline="") as f:
            writer = csv.writer(f)
            row = [
                metrics_data["collection_timestamp"],
                metrics_data["collection_time"],
            ]
            for column in all_metric_columns:
                # Check if this is a histogram column with percentile suffix
                # Format: "vllm:time_to_first_token_seconds:p95"
                # We need to find the LAST colon to split metric name from percentile key
                parts = column.rsplit(":", 1)
                if len(parts) == 2 and parts[1] in ["avg", "p50", "p90", "p95", "p99"]:
                    # Histogram metric with percentile
                    metric_name, key = parts
                    value = metrics_data["metrics"].get(metric_name, {}).get(key)
                else:
                    # Simple metric (gauge or counter)
                    value = metrics_data["metrics"].get(column, {}).get("value")
                row.append(value if value is not None else "")
            writer.writerow(row)

    def _write_json(self):
        """Write all collected metrics to JSON file"""
        with open(self.json_file, "w") as f:
            json.dump(
                {
                    "metadata": {
                        "thanos_url": self.thanos_url,
                        "collection_interval": self.collection_interval,
                        "labels": self.labels,
                        "start_time": self.all_metrics[0]["collection_time"]
                        if self.all_metrics
                        else None,
                        "end_time": self.all_metrics[-1]["collection_time"]
                        if self.all_metrics
                        else None,
                        "total_collections": len(self.all_metrics),
                    },
                    "metrics": self.all_metrics,
                },
                f,
                indent=2,
            )

    def run(self):
        """Main collection loop"""
        logger.info("Starting metrics collection...")

        collection_count = 0
        all_metric_columns = None

        try:
            while self.running:
                collection_count += 1
                logger.info(f"Collection #{collection_count}")

                # Collect metrics
                metrics_data = self.collect_metrics()
                self.all_metrics.append(metrics_data)

                # Get all metric columns from first collection for CSV header
                if collection_count == 1:
                    all_metric_columns = self._get_all_metric_columns(metrics_data)
                    self._write_csv_header(all_metric_columns)

                # Write to CSV
                self._append_to_csv(metrics_data, all_metric_columns)

                # Log summary - count non-null values separately for vLLM and node metrics
                vllm_success = 0
                vllm_total = 0
                node_success = 0
                node_total = 0

                for metric_name, metric_info in metrics_data["metrics"].items():
                    is_node = metric_name.startswith("node_")
                    has_data = False

                    if "value" in metric_info:
                        if metric_info["value"] is not None:
                            has_data = True
                    else:
                        # Histogram with multiple values
                        for key, val in metric_info.items():
                            if key != "type" and val is not None:
                                has_data = True
                                break

                    if is_node:
                        node_total += 1
                        if has_data:
                            node_success += 1
                    else:
                        vllm_total += 1
                        if has_data:
                            vllm_success += 1

                total_metrics = len(metrics_data["metrics"])
                logger.info(
                    f"Collected {vllm_success + node_success}/{total_metrics} metrics "
                    f"(vLLM: {vllm_success}/{vllm_total}, Node: {node_success}/{node_total})"
                )

                # Warn if no vLLM metrics collected
                if vllm_total > 0 and vllm_success == 0:
                    logger.warning(
                        "⚠️  No vLLM metrics collected! Check Thanos URL, authentication, "
                        "and that vLLM metrics exist. Run with --log-level DEBUG for details."
                    )

                # Sleep until next collection
                if self.running:
                    time.sleep(self.collection_interval)

        except Exception as e:
            logger.error(f"Error in collection loop: {e}", exc_info=True)

        finally:
            # Write final JSON output
            logger.info("Writing final JSON output...")
            self._write_json()

            logger.info(f"Collection complete. Total collections: {collection_count}")
            logger.info(f"CSV output: {self.csv_file}")
            logger.info(f"JSON output: {self.json_file}")


def parse_labels(label_str: str) -> Dict[str, str]:
    """Parse label string in format key1=value1,key2=value2"""
    if not label_str:
        return {}

    labels = {}
    for pair in label_str.split(","):
        if "=" in pair:
            key, value = pair.split("=", 1)
            labels[key.strip()] = value.strip()
    return labels


def main():
    parser = argparse.ArgumentParser(
        description="Collect vLLM metrics from Thanos Querier and node metrics"
    )
    parser.add_argument(
        "--thanos-url", required=True, help="Thanos Querier endpoint URL"
    )
    parser.add_argument("--output-dir", required=True, help="Directory to save metrics")
    parser.add_argument(
        "--interval",
        type=int,
        default=1,
        help="Collection interval in seconds (default: 1)",
    )
    parser.add_argument(
        "--metrics",
        help="Comma-separated list of vLLM metrics to collect (uses defaults if not specified)",
    )
    parser.add_argument(
        "--labels", help="Label filters in format key1=value1,key2=value2"
    )
    parser.add_argument(
        "--no-node-metrics",
        action="store_true",
        help="Disable node metrics collection (CPU, memory, network, disk)",
    )
    parser.add_argument(
        "--log-level",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        default="INFO",
        help="Logging level (default: INFO)",
    )
    parser.add_argument(
        "--token-file",
        help="Path to ServiceAccount token file for authentication (default: /var/run/secrets/kubernetes.io/serviceaccount/token)",
        default="/var/run/secrets/kubernetes.io/serviceaccount/token",
    )
    parser.add_argument(
        "--rate-interval",
        default="1m",
        help="Time window for rate() calculations for Counter metrics (default: 1m)",
    )

    args = parser.parse_args()

    # Set log level
    logger.setLevel(getattr(logging, args.log_level))

    # Parse metrics and labels
    metrics = args.metrics.split(",") if args.metrics else None
    labels = parse_labels(args.labels)

    # Create and run collector
    collector = MetricsCollector(
        thanos_url=args.thanos_url,
        output_dir=args.output_dir,
        collection_interval=args.interval,
        metrics=metrics,
        labels=labels,
        collect_node_metrics=not args.no_node_metrics,
        token_file=args.token_file,
        rate_interval=args.rate_interval,
    )

    collector.run()


if __name__ == "__main__":
    main()
