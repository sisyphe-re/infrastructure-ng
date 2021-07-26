from sisyphe.celery import app
from . import models
import subprocess, os, random, signal, time, string, uuid, datetime, tempfile, json
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend
import libvirt

def id_generator(size=6, chars=string.ascii_uppercase + string.digits):
    return ''.join(random.choice(chars) for _ in range(size))

def get_domain(uuid_str, qcow_path, dirname, ssh_port):
    return f'''
<domain type='kvm' id='2' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
        <name>{uuid_str}</name>
        <memory unit='GiB'>2</memory>
        <vcpu placement='static'>2</vcpu>
        <os>
                <type arch='x86_64' machine='pc-q35-6.0'>hvm</type>
                <boot dev='hd'/>
        </os>
        <features>
                <acpi/>
                <apic/>
        </features>
        <devices>
                <emulator>/run/current-system/sw/bin/qemu-system-x86_64</emulator>
                <disk type='file' device='disk'>
                        <driver name='qemu' type='qcow2'/>
                        <source file='{qcow_path}' index='1'/>
                        <backingStore/>
                        <target dev='vda' bus='virtio'/>
                        <alias name='virtio-disk0'/>
                        <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
                </disk>
                <filesystem type='mount' accessmode='squash'>
                        <source dir='{dirname}'/>
                        <target dir='srv'/>
                        <alias name='fs0'/>
                        <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
                </filesystem>
                <serial type='pty'>
                        <source path='/dev/pts/3'/>
                        <target type='isa-serial' port='0'>
                                <model name='isa-serial'/>
                        </target>
                        <alias name='serial0'/>
                </serial>
                <console type='pty' tty='/dev/pts/3'>
                        <source path='/dev/pts/3'/>
                        <target type='serial' port='0'/>
                        <alias name='serial0'/>
                </console>
        </devices>
        <qemu:commandline>
                <qemu:arg value='-netdev'/>
                <qemu:arg value='user,id=mynet.0,net=10.0.10.0/24,hostfwd=tcp::{ssh_port}-:22'/>
                <qemu:arg value='-device'/>
                <qemu:arg value='e1000,netdev=mynet.0'/>
        </qemu:commandline>
</domain>
    '''

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
        process = subprocess.run(f"cd {dirname} && cp $SISYPHE_ISO_PATH/*.qcow2 /var/tmp/sisyphe_{uuid_str}_nixos.qcow2 && chmod u+w /var/tmp/sisyphe_{uuid_str}_nixos.qcow2", stdout=out, stderr=err, shell=True, env=environment)

    print("Injecting secrets into the VM...")
    tmp_env = tempfile.NamedTemporaryFile(mode='w+t')
    guestfish_commands = tempfile.NamedTemporaryFile(mode='w+t')
    domain = tempfile.NamedTemporaryFile(mode='w+t', delete=False)
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
            f'mkdir /root/.ssh/\n'
            f'write /root/.ssh/authorized_keys "{public_key_str}"\n'
            f'quit'
    )
    guestfish_commands.file.flush()
    domain.write(get_domain(uuid_str, f"/var/tmp/sisyphe_{uuid_str}_nixos.qcow2", dirname, sshPort))
    domain.file.flush()

    process = subprocess.run(f"guestfish --file {guestfish_commands.name}", shell=True, env=environment)

    print("Launching the VM...")
    with open(f"{dirname}/vm_run.stdout.txt","wb") as out, open(f"{dirname}/vm_run.stderr.txt","wb") as err:
        print(f"virsh define {domain.name}; virsh start {uuid_str}")
        process = subprocess.Popen(f"ls -alh {domain.name}; cat {domain.name}; virsh define {domain.name}; virsh start {uuid_str}", stdout=out, stderr=err, shell=True, preexec_fn=os.setsid, env=environment)
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
    print(f"Shutdown of the VM")
    dirname = f"/home/sisyphe/{run.uuid}"
    with open(f"{dirname}/stop_stdout.txt","wb") as out, open(f"{dirname}/stop_stderr.txt","wb") as err:
        process = subprocess.Popen(f"virsh shutdown {uuid}", shell=True, env=environment)
        run.end = datetime.datetime.now()
        run.hidden = False
        run.save()
