# Generated by Django 3.2.2 on 2021-06-17 13:29

from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    initial = True

    dependencies = [
    ]

    operations = [
        migrations.CreateModel(
            name='Campaign',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('name', models.CharField(max_length=100)),
                ('source', models.URLField()),
                ('duration', models.IntegerField(default=600)),
            ],
        ),
        migrations.CreateModel(
            name='Run',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('start', models.DateTimeField(auto_now_add=True)),
                ('end', models.DateTimeField(blank=True, null=True)),
                ('campaign', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, to='api.campaign')),
            ],
        ),
        migrations.CreateModel(
            name='Process',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('pid', models.IntegerField()),
                ('running', models.BooleanField(default=True)),
                ('sshPort', models.IntegerField()),
                ('run', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, to='api.run')),
            ],
        ),
        migrations.CreateModel(
            name='EnvironmentVariable',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('key', models.TextField()),
                ('value', models.TextField()),
                ('campaign', models.ManyToManyField(to='api.Campaign')),
            ],
        ),
    ]
