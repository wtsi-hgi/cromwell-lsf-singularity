# Olly Maersk

**Containerisation-agnostic LSF provider for Cromwell**

This provides the configuration and shims required to run jobs under
[Cromwell](https://cromwell.readthedocs.io/en/stable/), using LSF as an
executor, with the option of running jobs containerised in
[Singularity](https://www.sylabs.io/singularity/) or Docker containers.
It "massages" Cromwell's assumptions about Docker, such that prebaked
Dockerised workflows should work without change.

## Getting Started

This presumes you have downloaded Cromwell; if not, you may follow their
[Five Minute Introduction](https://cromwell.readthedocs.io/en/stable/tutorials/FiveMinuteIntro/)
to get set up. You'll also need an LSF cluster with Singularity
installed.

There are four separate files you'll need to drive your workflow:

1. The Cromwell configuration, including the configuration provided in
   this repository to set the backend executor. A minimal working
   example would look like:

   ```hocon
   include required(classpath("application"))

   backend {
     default = "ContainerisedLSF"

     providers {
       ContainerisedLSF {
         include required("/path/to/containerised-lsf.inc.conf")
       }
     }
   }
   ```

2. The actual workflow definition (WDL) file, itself.

3. A workflow inputs file (JSON), which defines the variables used in
   the workflow definition (e.g., location of data files, etc.), if any.
   (If a workflow has no inputs, then this is not required.)

4. A workflow options file (JSON), which defines how the workflow tasks
   ought to be run.

For the purpose of this exercise, we shall create a simple workflow
definition that says "Hello, World!", within a Ubuntu Docker container,
submitted to LSF:

```wdl
workflow example {
  call hello
}

task hello {
  String who

  runtime {
    docker: "ubuntu"
  }

  command {
    echo 'Hello, ${who}!'
  }

  output {
    String out = read_string(stdout())
  }
}
```

The `hello` task is Dockerised simply by virtue of the existence of the
`docker` runtime variable, which defines the container image. Our
submission shim, which uses Singularity, will recognise this and convert
it into something that Singularity can understand, before submitting it
to LSF. This way, production workflow definitions that use Docker will
just work, without modification.

When writing your own workflow, where you'd rather use Singularity
directly, over an emulation of Docker, you can instead set the
`singularity` runtime variable. This also defines the container image
and can be set to anything that Singularity understands:

* An image available on your filesystem;
* A directory that contains a valid root filesystem;
* An instance of a locally running container (prefixed with
  `instance://`);
* A container hosted on [Singularity Hub](https://www.singularity-hub.org/)
  (prefixed with `shub://`);
* A container hosted on [Docker Hub](https://hub.docker.com/)
  (prefixed with `docker://`).

Our above example workflow references a variable, `who`, which must be
supplied to our workflow through an inputs file, like so:

```json
{
  "example.hello.who": "World"
}
```

Finally, because we are farming our jobs out to LSF, we must tell LSF
how to schedule our job. This covers things like resource allocation,
queue name and group name. These are [documented
below](#lsf-runtime-attributes) and many have default values. If you are
writing your own workflow, then these too can be included in the
`runtime` declaration of your task. Alternatively, we can set them as
runtime defaults in a workflow options file:

```json
{
  "default_runtime_attributes": {
    "lsf_group": "hgi"
  }
}
```

To ensure that our submission shim (`submit.sh`) is available to
Cromwell, we must first add it to our `PATH` environment variable:

```bash
export PATH="/path/to/submission/shim:${PATH}"
```

Putting these all together, to run the workflow, we arrive at the
following command:

    java -Dconfig.file=example.conf -jar /path/to/cromwell.jar \
         run -i example.inputs.json -o example.options.json example.wdl

This runs Cromwell directly, rather than in server-mode, without an
external database to keep its state. The output of the job will be
within a directory named `cromwell-executions` (per the provider `root`
setting), which takes the following schema:

    cromwell-executions/${workflow}/${run_id}/call-${task}/[shard-${index}/][attempt-${count}/]execution

The `shard-${index}` subdirectories are only created by scatter tasks. If
a task fails, `attempt-${count}` subdirectories will be created, when
the `maxRetries` Cromwell runtime attribute is non-zero, until the task
succeeds or exceeds this limit.

The `run_id` will be generated by Cromwell and presented in its logs.
These logs will also echo the workflow's output, presuming all was
successful:

```
[2019-03-01 12:34:34,32] [info] WorkflowExecutionActor-f7407094-a771-4178-a623-ef857c96ce38 [f7407094]: Workflow example complete. Final Outputs:
{
  "example.hello.out": "Hello, World!"
}
```

**Note** The usual caveats about running a Java program on an LSF head
node apply. Specifically, Java will attempt to allocate as much memory
it can and, at least at Sanger, that will be prohibited. This can be
worked around by specifying the `-Xms` and `-Xmx` flags or, better yet,
submitting Cromwell itself as a job.

## LSF Runtime Attributes

The following runtime attributes influence how a job is submitted to
LSF; they must all be specified, either explicitly or through their
default value:

| Attribute    | Default  | Usage                                           |
| :----------- | :------- | :---------------------------------------------- |
| `lsf_group`  |          | The Fairshare group under which to run the task |
| `lsf_queue`  | `normal` | The LSF queue in which to run the task          |
| `lsf_cores`  | 1        | The number of CPU cores required                |
| `lsf_memory` | 1000     | The amount of memory (in MB) required           |

Additional LSF resource requirements can also be specified by providing
an `lsf_resources` attribute. This is optional and its value takes the
same format as that recognised by the `-R` flag to LSF's `bsub`.

These attributes can be specified within a workflow task itself, or
injected as `default_runtime_attributes`.

## Non-Containerised Workflows

Tasks that do not define containers for their operation will be
submitted to run directly on an execution node of the LSF cluster.

## Singularity Workflows

*EXPERIMENTAL*

Tasks that define a `singularity` runtime value, specifically of the
fully qualified Singularity image identifier in which the task should
run, will be submitted to LSF as jobs, with the appropriate directories
bind mounted. The output of the task will be written within the
container, but the mounting will ensure it is preserved on the host.

## Docker Workflows

*EXPERIMENTAL*

Tasks that define a `docker` runtime value, specifically of the
container image in which the task should run, will be submitted to LSF
as jobs, with the appropriate directories bind mounted. The output of
the task will be written within the container, but the mounting will
ensure it is preserved on the host.

## Zombified Tasks

Workflow tasks are submitted to LSF as jobs, which can die due to events
raised by the scheduler itself (e.g., `bkill`, reaching the runtime
limit, etc.) If such a job fails ungracefully, then Cromwell is not able
to identify that the encapsulated task has failed and will thus wait
indefinitely, in vain, for it to be reanimated.

To get around this problem, `zombie-killer.sh` will check the status of
all currently running workflows' tasks, by querying the Cromwell API
(i.e., this can only work when Cromwell is run in server-mode). If it
finds any tasks which are associated with dead jobs, which haven't been
gracefully closed off, it will forcibly mark them as completed (and
failed).

This script ought to be run periodically (e.g., an hourly `cron` job) to
clean up failures:

    ./zombie-killer.sh CROMWELL_WORKFLOW_API_URL

Where `CROMWELL_WORKFLOW_API_URL` is the full URL to Cromwell's RESTful
API workflow root (e.g., `http://cromwell:8000/api/workflows/v1`)

## Status Logging

The Cromwell executions directory can quickly become tiresome to
navigate, in order to manually construct the status of your running or
historical workflows. As such, the `status.sh` serves to give an
overview of any subset of workflows that Cromwell has executed.

Usage:

    ./status.sh [WORKFLOW_ID_PREFIX...]

The `WORKFLOW_ID_PREFIX` can be omitted to show everything under the
execution root directory, specified one-or-more times for particular
workflows, and needn't be complete (i.e., it will only report on
workflows whose IDs match the given prefix).

By default, the script will look for the execution root directory in
`cromwell-executions`, in the current working directory. This may be
overridden by setting the `EXECUTION_ROOT` environment variable.

## To Do...

- [ ] Better management around Cromwell's assumptions about Docker
      submissions.
- [ ] Better interface for user-defined mount points for containers.
