# cf-vector-buildpack

Cloudfoundry buildpack to manage application logs

## Using it

blabla

and run `cf push`


## Settings

Parameters are set via environment these environment variables:

```
```


# Development

Implemented using bash scripts to make it easy to understand and change.

https://docs.cloudfoundry.org/buildpacks/understand-buildpacks.html

The builpack uses the `deps` and `cache` folders according the implementation purposes,
so, the first time the buildpack is used it will download all resources, next times 
it will use the cached resources.


# Author

(c) Jose Riguera Lopez  <jose.riguera@springernature.com>
Springernature Engineering Enablement

MIT License
