ARG FUNCTION_DIR="/function"

# Define Chainguard org to pull images from
ARG CHAINGUARD_ORG=chainguard

# Use -dev variant to install dependencies with pip
FROM cgr.dev/${CHAINGUARD_ORG}/python:latest-dev AS build-image

# Include global arg in this stage of the build
ARG FUNCTION_DIR

# Create work dir
WORKDIR ${FUNCTION_DIR}

# Install the function's dependencies
COPY requirements.txt requirements.txt
RUN pip install \
    --target ${FUNCTION_DIR} \
    -r requirements.txt && rm requirements.txt

# Copy function code
COPY lambda_function.py lambda_function.py

# Use a prod version of the base Python image to reduce the final image size and
# exclude unnecessary packages at runtime
FROM cgr.dev/${CHAINGUARD_ORG}/python:latest

# Include global arg in this stage of the build
ARG FUNCTION_DIR

# Set working directory to function root directory
WORKDIR ${FUNCTION_DIR}

# Copy in the built dependencies
COPY --from=build-image ${FUNCTION_DIR} ${FUNCTION_DIR}

# Set runtime interface client as default command for the container runtime
ENTRYPOINT [ "/usr/bin/python", "-m", "awslambdaric" ]

# Pass the name of the function handler as an argument to the runtime
CMD [ "lambda_function.handler" ]
