from setuptools import setup

setup(
    name='vauban',
    version='1.0.0',
    py_modules=['vauban'],
    install_requires=[
        'Click',
        'pyyaml',
    ],
    entry_points={
        'console_scripts': [
            'vauban = vauban:vauban',
        ],
    },
)
