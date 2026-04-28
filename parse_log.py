import json

with open('/Users/kael/.gemini/antigravity/brain/92a1dc32-d8aa-4b1b-9d13-bad246b7b2e4/.system_generated/logs/overview.txt', 'r') as f:
    for line in f:
        try:
            data = json.loads(line)
            if 'tool_calls' in data:
                for t in data['tool_calls']:
                    if t['name'] == 'replace_file_content':
                        rep = t['args'].get('ReplacementContent', '')
                        if 'YinYangIcon' in rep or 'SettingsButton' in rep:
                            print(f"--- Step {data['step_index']} Replace ---")
                            print("Replacement:", rep)
        except Exception as e:
            pass

