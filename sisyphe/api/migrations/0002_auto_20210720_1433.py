# Generated by Django 3.2.5 on 2021-07-20 14:33

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0001_initial'),
    ]

    operations = [
        migrations.AddField(
            model_name='run',
            name='hidden',
            field=models.BooleanField(default=True),
        ),
        migrations.AddField(
            model_name='run',
            name='uuid',
            field=models.CharField(default='', max_length=100),
        ),
    ]
