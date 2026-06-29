import os
import glob

directory = r"d:\LeHoangViet-aws-accelerator-p2\cloud\capstone\w11\capstone-phase2\capstone\tf-3\cdo-1\gitops\argo-apps"
files = glob.glob(os.path.join(directory, "*.yaml"))

for file in files:
    with open(file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    content = content.replace("repoURL: https://github.com/truongcongtu318/capstone-phase2.git", "repoURL: https://git-codecommit.us-east-1.amazonaws.com/v1/repos/tf3-cdo1-sandbox-gitops")
    content = content.replace("targetRevision: team-3", "targetRevision: main")
    
    with open(file, 'w', encoding='utf-8') as f:
        f.write(content)

print("Replaced all occurrences successfully.")
