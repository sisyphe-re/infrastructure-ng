from sisyphe.celery import app
from . import models
import subprocess, os, random, signal, time, string, uuid, datetime, tempfile, json
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend
import libvirt


class LibVirtWorker:
    def __init__(self, instance_id):
        self.pool_name = "sisyphe-disks"
        self.pool_path = "/var/tmp"
        self.uuid = str(uuid.uuid4())
        self.instance_id = instance_id
        self.volume_name = f"volume_{self.uuid}_nixos.qcow2"
        self.environment = os.environ.copy()
        self.backing_image_path = self.environment["SISYPHE_ISO_PATH"] + "/nixos.qcow2"

        self.process = None
        self.campaign = models.Campaign.objects.get(id=self.instance_id)
        self.run = models.Run.objects.create(campaign=self.campaign, uuid=self.uuid)

        # Generate Unique Directory
        self.dirname = f"/home/sisyphe/{self.uuid}"
        os.makedirs(self.dirname)
        # SSH
        self.ssh_port = random.randint(10000, 40000)
        self.private_key = None
        self.public_key = None

    def connect(self):
        try:
            self.connection = libvirt.open(None)
        except libvirt.libvirtError:
            print('Failed to open connection to the hypervisor')
            exit(1)

    def disconnect(self):
        self.connection.close()
        self.connection = None

    def ensure_pool_exists(self):
        try:
            self.pool = self.connection.storagePoolLookupByName(self.pool_name)
        except libvirt.libvirtError:
            print("The pool does not exist")
            poolXML = f'''
            <pool type='dir'>
              <name>{self.pool_name}</name>
              <uuid/>
              <source>
              </source>
              <target>
                <path>{self.pool_path}</path>
                <permissions>
                  <mode>0755</mode>
                  <owner>-1</owner>
                  <group>-1</group>
                </permissions>
              </target>
            </pool>
            '''
            self.pool = self.connection.storagePoolDefineXML(poolXML, 0)
            self.pool.setAutostart(1)
            self.pool.create()
        if not self.pool.isActive():
            self.pool.create()

    def create_volume(self):
        print(f"Backing image path: {self.backing_image_path}")
        volumeXML = f'''
            <volume type='file'>
                <name>{self.volume_name}</name>
                <capacity unit='G'>10</capacity>
                <target>
                        <format type='qcow2'/>
                        <permissions>
                        <mode>0600</mode>
                        </permissions>
                </target>
                <backingStore>
                        <path>{self.backing_image_path}</path>
                        <format type='qcow2'/>
                </backingStore>
            </volume>
        '''
        self.pool.createXML(volumeXML)

    def create_domain(self):
        domainXML = f'''
            <domain type='kvm' id='2' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
                    <name>{self.uuid}</name>
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
                            <disk type="volume" device="disk">
                                    <driver name='qemu' type='qcow2' />
                                    <source type="volume" pool="{self.pool_name}" volume="{self.volume_name}" />
                                    <backingStore type='file'>
                                        <source file='{self.backing_image_path}'/>
                                        <format type='qcow2'/>
                                    </backingStore>
                                    <target dev="vda" bus="virtio"/>
                                    <alias name='virtio-disk0'/>
                                    <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
                            </disk>
                            <filesystem type='mount' accessmode='squash'>
                                    <source dir='{self.dirname}'/>
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
                            <qemu:arg value='user,id=mynet.0,net=10.0.10.0/24,hostfwd=tcp::{self.ssh_port}-:22'/>
                            <qemu:arg value='-device'/>
                            <qemu:arg value='e1000,netdev=mynet.0'/>
                    </qemu:commandline>
            </domain>
        '''
        self.connection.createXML(domainXML)
        self.process = models.Process.objects.create(run=self.run, pid=0, sshPort=self.ssh_port)

    def configure_domain(self):
        # Configure SSH
        print(f"The ssh server will run on {self.ssh_port}")
        key = rsa.generate_private_key(backend=default_backend(), public_exponent=65537, key_size=2048)
        pub_key = key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH)
        pem = key.private_bytes(encoding=serialization.Encoding.PEM, format=serialization.PrivateFormat.TraditionalOpenSSL, encryption_algorithm=serialization.NoEncryption())
        self.private_key = pem.decode('utf-8')
        self.public_key = pub_key.decode('utf-8')

        # Expose the ssh port on the host
        self.environment["QEMU_NET_OPTS"] = f"hostfwd=tcp::{self.ssh_port}-:22"
        self.environment["SSH_PUBLIC_KEY"] = self.public_key

        # Manage Additional Environment Variable
        custom_env = {}
        custom_env_list = []
        for env_var in models.EnvironmentVariable.objects.filter(campaign__id=self.instance_id):
                custom_env_list.append(f'{env_var.key}="{env_var.value}"\n')
                custom_env[env_var.key] = env_var.value

        print("Injecting secrets into the VM...")
        tmp_env = tempfile.NamedTemporaryFile(mode='w+t')
        guestfish_commands = tempfile.NamedTemporaryFile(mode='w+t')
        tmp_env.write(
                f'REPOSITORY="{self.campaign.source}"\n'
                f'SSH_PORT="{self.ssh_port}"\n'
                f'SSH_HOST="{os.environ.get("DJANGO_HOST")}"\n'
                f'SSH_USER="root"\n'
                f'SSH_PUBLIC_KEY="{self.public_key}"\n'
                f'SSH_PRIVATE_KEY="{self.private_key}"\n'
                ''.join(custom_env_list)
                )
        tmp_env.file.flush()

        guestfish_commands.write(
                f'add /var/tmp/{self.volume_name}\n'
                f'run\n'
                f'mount /dev/sda1 /\n'
                f'upload {tmp_env.name} /etc/sisyphe_secrets\n'
                f'mkdir /root/.ssh/\n'
                f'write /root/.ssh/authorized_keys "{self.public_key}"\n'
                f'quit'
        )
        guestfish_commands.file.flush()

        process = subprocess.run(f"guestfish --file {guestfish_commands.name}", shell=True, env=self.environment)


@app.task
def runCampaign(instance_id):
    worker = LibVirtWorker(instance_id)

    print("Connect to the hypervisor")
    worker.connect()

    print("Ensure the pool exists")
    worker.ensure_pool_exists()

    print("Setting up environment")
    environment = os.environ.copy()

    print("Creating a volume for the VM…")
    worker.create_volume()

    print("Configuring the VM…")
    worker.configure_domain()

    print(f"Creating and launching the domain…")
    worker.create_domain()

    print("Disconnect from the hypervisor")
    worker.disconnect()

    stopCampaign.apply_async(
        (worker.process.pk, worker.uuid,),   # args
        eta=datetime.datetime.now() + datetime.timedelta(minutes=worker.campaign.duration)
    )

@app.task(ignore_result=True)
def stopCampaign(pk, uuid):
    print(f"Shutdown of the VM")
    try:
        connection = libvirt.open(None)
        dom = connection.lookupByName(uuid)
        dom.shutdown()
        cleanupCampaign.apply_async(
            (pk, uuid,),
            eta=datetime.datetime.now() + datetime.timedelta(minutes=10)
        )
    except libvirt.libvirtError:
        print('Failed to open connection to the hypervisor')
        exit(1)
    print("Update the database")
    process = models.Process.objects.get(pk=pk)
    run = process.run
    run.end = datetime.datetime.now()
    run.hidden = False
    run.save()

@app.task(ignore_result=True)
def cleanupCampaign(pk, uuid):
    print("Cleanup of the volumes")
    try:
        connection = libvirt.open(None)
        dom = connection.lookupByName(uuid)
        if dom.isActive():
            cleanupCampaign.apply_async(
                (pk, uuid,),
                eta=datetime.datetime.now() + datetime.timedelta(minutes=10)
            )
        else:
            pool = conn.storagePoolLookupByName('sisyphe-disks')
            if not pool:
                print('Failed to locate the sisyphe-disks storage pool')
                exit(1)

            volume_name = f"volume_{uuid}_nixos.qcow2"
            vol = pool.storageVolLookupByName(volume_name)

            if not vol:
                print(f'Failed to locate the {volume_name} volume')
                exit(1)

            vol.wipe()
            vol.delete()
    except libvirt.libvirtError:
        print('Failed to open connection to the hypervisor')
        exit(1)