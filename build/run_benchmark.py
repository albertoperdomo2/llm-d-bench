import os
import sys
import subprocess
import json
import mlflow
import argparse
from datetime import datetime


def main():
    """
    Main function to run the GuideLLM benchmark and log results to MLflow.
    """
    parser = argparse.ArgumentParser(
        description="Run GuideLLM benchmark and log to MLflow."
    )
    parser.add_argument("--target", help="Target inference endpoint")
    parser.add_argument("--model", help="Model configuration")
    parser.add_argument("--processor", help="Processor for the model")
    parser.add_argument("--rate-type", help="Rate type (e.g., concurrent)")
    parser.add_argument("--rate", help="Rate of requests")
    parser.add_argument("--data", help="Data for the benchmark")
    parser.add_argument("--max-seconds", help="Maximum duration of the benchmark")
    # Capture any other arguments for guidellm
    parser.add_argument("additional_args", nargs=argparse.REMAINDER)

    args = parser.parse_args()

    # --- Setup ---
    work_dir = f"/tmp/benchmark-{datetime.now().strftime('%s')}"
    os.makedirs(work_dir, exist_ok=True)
    os.environ["GUIDELLM__LOGGING__LOG_FILE"] = f"{work_dir}/console.log"
    print(f"[JOB] Working directory: {work_dir}")

    hf_home = "/tmp/.huggingface"
    os.makedirs(hf_home, exist_ok=True)
    os.environ["HF_HOME"] = hf_home
    print(f"[JOB] Hugging Face home: {hf_home}")

    hf_token = os.environ.get("HF_CLI_TOKEN")
    if hf_token:
        print("[JOB] Logging into Hugging Face...")
        subprocess.run(["huggingface-cli", "login", "--token", hf_token], check=True)

    print("[JOB] Forming MLFLOW_ARTIFACTS_DESTINATION variable")
    os.environ["MLFLOW_ARTIFACTS_DESTINATION"] = (
        f"s3://{os.environ['MLFLOW_S3_BUCKET_NAME']}"
    )

    # Construct guidellm arguments from parsed args
    guidellm_args = []
    mlflow_params = {}
    for arg, value in vars(args).items():
        if arg == "additional_args":
            continue
        if value is not None:
            arg_name = f"--{arg.replace('_', '-')}"
            guidellm_args.extend([arg_name, str(value)])
            mlflow_params[arg] = value

    # Add any additional args
    if args.additional_args:
        guidellm_args.extend(args.additional_args)

    # --- MLflow Integration ---
    if not os.environ.get("MLFLOW_TRACKING_URI"):
        print("[JOB] MLFLOW_TRACKING_URI not set. Running benchmark without MLflow.")
        run_benchmark(work_dir, guidellm_args)
        return

    try:
        experiment_name = os.environ.get("MLFLOW_EXPERIMENT_NAME", "guidellm-benchmark")
        mlflow.set_experiment(experiment_name)
        print(f"[JOB] MLflow experiment set to: {experiment_name}")

        with mlflow.start_run() as run:
            print(f"[JOB] Started MLflow run: {run.info.run_id}")

            # Log parameters from CLI args
            mlflow.log_params(mlflow_params)
            print(f"[JOB] Parameters logged to MLflow: {mlflow_params}")

            # Log parameters from environment
            env_params = {
                key: value
                for key, value in os.environ.items()
                if key.startswith("GUIDELLM_") or key.startswith("BENCHMARK_")
            }
            mlflow.log_params(env_params)
            print(f"[JOB] Environment parameters logged to MLflow: {env_params}")

            # Run the benchmark
            exit_code = run_benchmark(work_dir, guidellm_args)

            # Log results
            log_mlflow_results(work_dir, exit_code)

    except Exception as e:
        print(f"[JOB] An error occurred during the MLflow tracked run: {e}")
        sys.exit(1)


def run_benchmark(work_dir, args):
    """
    Executes the guidellm benchmark command.
    """
    output_path = f"{work_dir}/output.json"
    command = ["guidellm", "benchmark", "run"] + args + ["--output-path", output_path]

    print(f"[JOB] Running command: {' '.join(command)}")
    result = subprocess.run(command)
    exit_code = result.returncode
    print(f"[JOB] GuideLLM completed with exit code: {exit_code}")

    if os.path.exists(output_path):
        subprocess.run(["sha256sum", output_path])
    else:
        print("[JOB] Error: Output file not found after benchmark run.")

    return exit_code


def log_mlflow_results(work_dir, exit_code):
    """
    Logs benchmark artifacts and metrics to MLflow.
    """
    print("[JOB] Logging results to MLflow...")
    output_file = f"{work_dir}/output.json"
    console_log = f"{work_dir}/console.log"

    # Log artifacts
    if os.path.exists(output_file):
        mlflow.log_artifact(output_file, artifact_path="results")
        try:
            with open(output_file, "r") as f:
                results = json.load(f)
            if isinstance(results, dict) and "metrics" in results:
                mlflow.log_metrics(results.get("metrics", {}))
        except (json.JSONDecodeError, TypeError) as e:
            print(
                f"[JOB] Warning: Could not parse or process output.json for metrics: {e}"
            )
    else:
        mlflow.log_param("error", "output_file_not_found")

    if os.path.exists(console_log):
        mlflow.log_artifact(console_log, artifact_path="logs")

    # Log exit code and set status
    mlflow.log_metric("guidellm_exit_code", exit_code)
    status = "success" if exit_code == 0 else "failed"
    mlflow.set_tag("status", status)
    print("[JOB] Results logged to MLflow successfully")

    if exit_code != 0:
        print(f"[JOB] Benchmark failed with exit code: {exit_code}")
        sys.exit(exit_code)
    else:
        print("[JOB] Benchmark completed successfully!")


if __name__ == "__main__":
    main()
