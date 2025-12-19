import argparse
import json
import os
import numpy as np
import yaml
from bs4 import BeautifulSoup

def calculate_metrics(values):
    if not values:
        return {
            'max': None,
            'p50': None,
            'p95': None,
            'p99': None,
            'min': None,
            'count': 0
        }
    values = np.array(values, dtype=float)  # Change to float
    return {
        'max': np.max(values),
        'p50': np.percentile(values, 50),
        'p95': np.percentile(values, 95),
        'p99': np.percentile(values, 99),
        'min': np.min(values),
        'count': len(values)
    }

def get_client_results(results_path):
    client_results = {}
    for filename in os.listdir(results_path):
        if filename.endswith('.txt') and filename != "computer_specs.txt":
            parts = filename.rsplit('_', 3)
            if len(parts) == 4:
                client, run, part, size = parts
                size = size.replace('.txt', '')
                try:
                    run = int(run)
                    with open(os.path.join(results_path, filename), 'r') as file:
                        content = file.read().strip()
                        print(f"Reading file {filename} content: {content}")  # Debug line
                        value = float(content)  # Change to float
                except ValueError:
                    print(f"Skipping file {filename} due to invalid content")
                    continue
                except Exception as e:
                    print(f"Error reading file {filename}: {e}")
                    continue
                client = client  # Keep only the client name, ignore run
                if client not in client_results:
                    client_results[client] = {}
                if size not in client_results[client]:
                    client_results[client][size] = {}
                if part not in client_results[client][size]:
                    client_results[client][size][part] = []
                client_results[client][size][part].append(value)
                print(f"Added value for size {size}, client {client}, part {part}: {value}")
            else:
                print(f"Filename {filename} does not match expected pattern")
    return client_results

def process_client_results(client_results):
    processed_results = {}
    for client, sizes in client_results.items():
        processed_results[client] = {}
        for size, parts in sizes.items():
            processed_results[client][size] = {}
            for part, values in parts.items():
                processed_results[client][size][part] = calculate_metrics(values)
    return processed_results

def convert_to_gigabytes_str(value_in_megabytes):
    if value_in_megabytes < 0:
        return "∞"
    return f"{value_in_megabytes / 1024:.2f}G"

def generate_json_report(processed_results, results_path):
    report_path = os.path.join(results_path, 'reports')
    os.makedirs(report_path, exist_ok=True)
    with open(os.path.join(report_path, 'memory.json'), 'w') as json_file:
        json.dump(processed_results, json_file, indent=4)

def generate_html_report(processed_results, results_path, images, computer_spec):
    html_content = ('<!DOCTYPE html>'
                    '<html lang="en">'
                    '<head>'
                    '    <meta charset="UTF-8">'
                    '    <meta name="viewport" content="width=device-width, initial-scale=1.0">'
                    '    <title>Benchmarking Report</title>'
                    '    <style>'
                    '        body { font-family: Arial, sans-serif; }'
                    '        table { border-collapse: collapse; margin-bottom: 20px; }'
                    '        th, td { border: 1px solid #ddd; padding: 8px; text-align: center; }'
                    '        th { background-color: #f2f2f2; }'
                    '    </style>'
                    '</head>'
                    '<body>'
                    '<h2>Benchmarking Report</h2>'
                    f'<h3>Computer Specs</h3><pre>{computer_spec}</pre>')
    image_json = json.loads(images)
    for client, sizes in processed_results.items():
        image_to_print = image_json.get(client, 'default')
        if image_to_print == 'default':
            with open('images.yaml', 'r') as f:
                el_images = yaml.safe_load(f)["images"]
            client_without_tag = client.split("_")[0]
            image_to_print = el_images.get(client_without_tag, 'default')
        
        html_content += f'<h3>{client.capitalize()} - {image_to_print}</h3>'
        html_content += ('<table>'
                         '<thead>'
                         '<tr>'
                         '<th>Genesis File Size</th>'
                         '<th>Part</th>'
                         '<th>Max</th>'
                         '<th>p50</th>'
                         '<th>p95</th>'
                         '<th>p99</th>'
                         '<th>Min</th>'
                         '<th>Count</th>'
                         '</tr>'
                         '</thead>'
                         '<tbody>')
        # Sorting sizes by numeric value (assumes sizes are in the format like "1M", "10M", etc.)
        sorted_sizes = sorted(sizes.items(), key=lambda x: int(x[0].replace('M', '')))
        for size, parts in sorted_sizes:
            # Sorting parts by 'first' before 'second' and by run number
            sorted_parts = sorted(parts.items(), key=lambda x: (x[0],))
            for part, metrics in sorted_parts:
                html_content += (f'<tr><td>{size}</td>'
                                 f'<td>{part}</td>'
                                 f'<td>{convert_to_gigabytes_str(metrics["max"])}</td>'
                                 f'<td>{convert_to_gigabytes_str(metrics["p50"])}</td>'
                                 f'<td>{convert_to_gigabytes_str(metrics["p95"])}</td>'
                                 f'<td>{convert_to_gigabytes_str(metrics["p99"])}</td>'
                                 f'<td>{convert_to_gigabytes_str(metrics["min"])}</td>'
                                 f'<td>{metrics["count"]}</td></tr>')
        html_content += '</tbody></table>'
    html_content += '</body></html>'
    
    soup = BeautifulSoup(html_content, 'html.parser')
    formatted_html = soup.prettify()
    report_path = os.path.join(results_path, 'reports')
    os.makedirs(report_path, exist_ok=True)
    with open(os.path.join(report_path, 'memory.html'), 'w') as html_file:
        html_file.write(formatted_html)

def main():
    parser = argparse.ArgumentParser(description='Benchmark script')
    parser.add_argument('--resultsPath', type=str, help='Path to gather the results', default='results/memory')
    parser.add_argument('--images', type=str, help='Image values per each client',
                        default='{ "nethermind": "default", "besu": "default", "geth": "default", "reth": "default", "erigon": "default", "ethrex": "default" }')

    args = parser.parse_args()

    results_path = args.resultsPath
    images = args.images
    reports_path = os.path.join(results_path, 'reports')
    os.makedirs(reports_path, exist_ok=True)

    # Get the computer spec
    computer_spec_path = os.path.join(results_path, "computer_specs.txt")
    if os.path.exists(computer_spec_path):
        with open(computer_spec_path, 'r') as file:
            computer_spec = file.read().strip()
    else:
        computer_spec = "Not available"

    client_results = get_client_results(results_path)
    print("Client Results:", client_results)  # Add debug information

    processed_results = process_client_results(client_results)
    print("Processed Results:", processed_results)  # Add debug information

    generate_json_report(processed_results, results_path)
    generate_html_report(processed_results, results_path, images, computer_spec)

    print('Done!')

if __name__ == '__main__':
    main()