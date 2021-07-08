from sisyphe.celery import app
from . import models
import subprocess, os, random, signal, time, string, uuid, datetime, tempfile, json
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend

def id_generator(size=6, chars=string.ascii_uppercase + string.digits):
    return ''.join(random.choice(chars) for _ in range(size))

@app.task
def runCampaign(instance_id):
    print(f"Campaign ID is {instance_id}")
    campaign = models.Campaign.objects.get(id=instance_id)

    print("Creating a new run")
    uuid_str = uuid.uuid4()
    run = models.Run.objects.create(campaign=campaign, uuid=uuid_str)

    print("Setting up environment")
    environment = os.environ.copy()

    # URL of the campaign
    # environment["REPOSITORY"] = campaign.source

    # Generate Unique Directory
    dirname = f"/home/sisyphe/{uuid_str}"
    os.makedirs(dirname)
    #environment["HOME_DIRECTORY"] = dirname

    # SSH Port
    sshPort = random.randint(10000, 40000)
    print(f"The ssh server will run on {sshPort}")
    key = rsa.generate_private_key(backend=default_backend(), public_exponent=65537, key_size=2048)
    public_key = key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH)
    pem = key.private_bytes(encoding=serialization.Encoding.PEM, format=serialization.PrivateFormat.TraditionalOpenSSL, encryption_algorithm=serialization.NoEncryption())
    private_key_str = pem.decode('utf-8')
    public_key_str = public_key.decode('utf-8')

    # Expose the ssh port on the host
    environment["QEMU_NET_OPTS"] = f"hostfwd=tcp::{sshPort}-:22"
    environment["SSH_PUBLIC_KEY"] = public_key_str

    # Manage Additional Environment Variable
    custom_env = {}
    custom_env_list = []
    for env_var in models.EnvironmentVariable.objects.filter(campaign__id=instance_id):
        custom_env_list.append(f'{env_var.key}="{env_var.value}"\n')
        custom_env[env_var.key] = env_var.value

    print("Building a new VM...")
    with open(f"{dirname}/vm_build.stdout.txt","wb") as out, open(f"{dirname}/vm_build.stderr.txt","wb") as err:
        process = subprocess.run(f"cd {dirname} && export BUILD_PATH=$(nix-build-stable /etc/nixos/sisyphe/sisyphe/images.nix -A standalone.eval --no-out-link --arg nixosConfiguration /etc/nixos/sisyphe/sisyphe/configuration.nix) && cp $BUILD_PATH/*.qcow2 /var/tmp/sisyphe_{uuid_str}_nixos.qcow2 && chmod u+w /var/tmp/sisyphe_{uuid_str}_nixos.qcow2", stdout=out, stderr=err, shell=True, env=environment)

    print("Injecting secrets into the VM...")
    tmp_env = tempfile.NamedTemporaryFile(mode='w+t')
    guestfish_commands = tempfile.NamedTemporaryFile(mode='w+t')
    tmp_env.write(
            f'REPOSITORY="{campaign.source}"\n'
            f'SSH_PORT="{sshPort}"\n'
            f'SSH_HOST="{os.environ.get("DJANGO_HOST")}"\n'
            f'SSH_USER="root"\n'
            f'SSH_PUBLIC_KEY="{public_key_str}"\n'
            f'SSH_PRIVATE_KEY="{private_key_str}"\n'
            ''.join(custom_env_list)
            )
    tmp_env.file.flush()
    guestfish_commands.write(
            f'add /var/tmp/sisyphe_{uuid_str}_nixos.qcow2\n'
            f'run\n'
            f'mount /dev/sda1 /\n'
            f'upload {tmp_env.name} /etc/sisyphe_secrets\n'
            f'quit'
    )
    guestfish_commands.file.flush()
    process = subprocess.run(f"guestfish --file {guestfish_commands.name}", shell=True, env=environment)

    f"hostfwd=tcp::{sshPort}-:22"
    print("Launching the VM...")
    with open(f"{dirname}/vm_run.stdout.txt","wb") as out, open(f"{dirname}/vm_run.stderr.txt","wb") as err:
        process = subprocess.Popen(f"cd {dirname} && qemu-system-x86_64 --cpu host --enable-kvm -drive file=/var/tmp/sisyphe_{uuid_str}_nixos.qcow2 -m 2048 -nographic -nic user,hostfwd=tcp::{sshPort}-:22,smb={dirname},smbserver=10.0.2.4", stdout=out, stderr=err, shell=True, preexec_fn=os.setsid, env=environment) 
        process = models.Process.objects.create(run=run, pid=process.pid, sshPort=sshPort)

        stopCampaign.apply_async(
                (process.pk,),   # args
                eta=datetime.datetime.now() + datetime.timedelta(minutes=campaign.duration)
                )

# Task to send one update.
@app.task(ignore_result=True)
def stopCampaign(process_id):
    print("Setting up environment")
    environment = os.environ.copy()
    process = models.Process.objects.get(pk=process_id)
    run = process.run
    uuid = run.uuid
    print(f"Killing the process of pid {process_id}")
    dirname = f"/home/sisyphe/{run.uuid}"
    with open(f"{dirname}/stop_stdout.txt","wb") as out, open(f"{dirname}/stop_stderr.txt","wb") as err:
        os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        run.end = datetime.datetime.now()
        run.save()
        # Clean up qcow2
        subprocess.run(f"rm /var/tmp/sisyphe_{uuid}_nixos.qcow2", shell=True, env=environment)
