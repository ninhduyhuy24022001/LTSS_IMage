    #include <stdio.h>

    #define CHECK(call)\
    {\
        const cudaError_t error = call;\
        if (error != cudaSuccess)\
        {\
            fprintf(stderr, "Error: %s:%d, ", __FILE__, __LINE__);\
            fprintf(stderr, "code: %d, reason: %s\n", error,\
                    cudaGetErrorString(error));\
            exit(EXIT_FAILURE);\
        }\
    }

    struct GpuTimer
    {
        cudaEvent_t start;
        cudaEvent_t stop;

        GpuTimer()
        {
            cudaEventCreate(&start);
            cudaEventCreate(&stop);
        }

        ~GpuTimer()
        {
            cudaEventDestroy(start);
            cudaEventDestroy(stop);
        }

        void Start()
        {
            cudaEventRecord(start,0);
            cudaEventSynchronize(start);
        }

        void Stop()
        {
            cudaEventRecord(stop, 0);
        }

        float Elapsed()
        {
            float elapsed;
            cudaEventSynchronize(stop);
            cudaEventElapsedTime(&elapsed, start, stop);
            return elapsed;
        }
    };

    __global__ void addVecKernel(int *in1, int *in2, int n, 
            int *out)
    {
        int i = blockIdx.x * blockDim.x + threadIdx.x; 

        if (i < n)
        {
            out[i] = in1[i] + in2[i];
        }
    }

    void addVec(int *in1, int *in2, int n, 
            int *out, 
            bool useDevice=false, dim3 blockSize=dim3(1), int nStreams=1)
    {
        if (useDevice == false)
        {
            for (int i = 0; i < n; i++)
            {
                out[i] = in1[i] + in2[i];
            }
        }
        else // Use device
        {
            cudaDeviceProp devProp;
            cudaGetDeviceProperties(&devProp, 0);
            printf("GPU name: %s\n", devProp.name);
            printf("GPU compute capability: %d.%d\n", devProp.major, devProp.minor);
            
            // Pin host memory regions (allocated by malloc)
            // so that we can use cudaMemcpyAsync  
            size_t nBytes = n * sizeof(int);
            CHECK(cudaHostRegister(in1, nBytes, cudaHostRegisterDefault));
            CHECK(cudaHostRegister(in2, nBytes, cudaHostRegisterDefault));
            CHECK(cudaHostRegister(out, nBytes, cudaHostRegisterDefault));

            // TODO: Allocate device memory regions
            int *d_in1, *d_in2, *d_out;
            CHECK(cudaMallocHost(&d_in1, nBytes));
            CHECK(cudaMallocHost(&d_in2, nBytes));
            CHECK(cudaMalloc(&d_out, nBytes))

            // TODO: Create "nStreams" device streams
            cudaStream_t* streams = (cudaStream_t*)malloc(nStreams * sizeof(cudaStream_t));
            for (int i = 0; i < nStreams; i++){
                cudaStreamCreate(&streams[i]);
            }
                // Create event
            cudaEvent_t startEvent, stopEvent;
            CHECK(cudaEventCreate(&startEvent));
            CHECK(cudaEventCreate(&stopEvent));
                // Send start event to null stream;

            GpuTimer timer;
            timer.Start();

            // TODO: Send jobs (H2D, kernel, D2H) to device streams
            int streamSize = n/nStreams + 1;
            // int streamBytes = streamSize*sizeof(int);
            // dim3 gridSize((streamSize - 1) / blockSize.x + 1);


            cudaEventRecord(startEvent, 0);
            for (int i = 0; i < nStreams; i++){
                int offset;
                int offsetIndex = i*streamSize;
                if (i == (nStreams-1)){
                    offset = (n - i*streamSize);
                }
                else
                    offset =  streamSize;

                dim3 gridSize((offset - 1) / blockSize.x + 1);
                int offsetBytes = offset*sizeof(int);

                // printf("%d\n", offsetIndex);

                CHECK(cudaMemcpyAsync(&d_in1[offsetIndex], &in1[offsetIndex], 
                                    offsetBytes, cudaMemcpyHostToDevice, streams[i]));
                CHECK(cudaMemcpyAsync(&d_in2[offsetIndex], &in2[offsetIndex], 
                                    offsetBytes, cudaMemcpyHostToDevice, streams[i]));
                addVecKernel<<<gridSize, blockSize, 0,  streams[i]>>>(&d_in1[offsetIndex], &d_in2[offsetIndex], offset, &d_out[offsetIndex]);
                CHECK(cudaMemcpyAsync(&out[offsetIndex], &d_out[offsetIndex],
                                    offsetBytes, cudaMemcpyDeviceToHost, streams[i]));
            }


            CHECK(cudaEventRecord(stopEvent, 0));
            CHECK(cudaEventSynchronize(stopEvent));

            timer.Stop();
            float time = timer.Elapsed();
            printf("Processing time of all device streams: %f ms\n\n", time);

            // TODO: Destroy device streams
            CHECK(cudaEventDestroy(startEvent));
            CHECK(cudaEventDestroy(stopEvent));

            for (int i = 0; i < nStreams; i++){
                cudaStreamDestroy(streams[i]);
            }

            // TODO: Free device memory regions
            cudaFreeHost(d_out);
            cudaFreeHost(d_in1);
            cudaFreeHost(d_in2);

            // Unpin host memory regions
            CHECK(cudaHostUnregister(in1));
            CHECK(cudaHostUnregister(in2));
            CHECK(cudaHostUnregister(out));
        }
    }

    int main(int argc, char ** argv)
    {
        int n; 
        int *in1, *in2; 
        int *out, *correctOut;

        // Input data into n
        n = (1 << 24) + 1;
        printf("n =  %d\n\n", n);

        // Allocate memories for in1, in2, out
        size_t nBytes = n * sizeof(int);
        in1 = (int *)malloc(nBytes);
        in2 = (int *)malloc(nBytes);
        out = (int *)malloc(nBytes);
        /*
        CHECK(cudaMallocHost(&in1, nBytes));
        CHECK(cudaMallocHost(&in2, nBytes));
        CHECK(cudaMallocHost(&out, nBytes));
        */
        correctOut = (int *)malloc(nBytes);

        // Input data into in1, in2
        for (int i = 0; i < n; i++)
        {
            in1[i] = rand() & 0xff; // Random int in [0, 255]
            in2[i] = rand() & 0xff; // Random int in [0, 255]
        }

        // Add in1 & in2 on host
        addVec(in1, in2, n, correctOut);

        // Add in1 & in2 on device
        dim3 blockSize(512); // Default
        int nStreams = 1; // Default
        if (argc >= 2)
        {
            blockSize.x = atoi(argv[1]);
            if (argc >= 3)
            {
                nStreams = atoi(argv[2]);
            }
        } 
        addVec(in1, in2, n, out, true, blockSize, nStreams);

        for (int i = 0; i < n; i++)
        {
            if (out[i] != correctOut[i])
            {
                printf("INCORRECT :(\n");
                return 1;
            }
        }

        printf("CORRECT :)\n");

        free(in1);
        free(in2);
        free(out);
        /*
        CHECK(cudaFreeHost(in1));
        CHECK(cudaFreeHost(in2));
        CHECK(cudaFreeHost(out));
        */
        free(correctOut);
    }
