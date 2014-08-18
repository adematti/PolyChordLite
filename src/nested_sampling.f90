module nested_sampling_module
    implicit none

    contains

    !> Main subroutine for computing a generic nested sampling algorithm
    subroutine NestedSampling(M,settings)
#ifdef MPI
        use mpi_module
#endif
        use model_module,    only: model
        use utils_module,    only: logzero
        use settings_module, only: program_settings
        use utils_module,    only: logsumexp
        use random_module,   only: random_integers
        use feedback_module

        implicit none
        type(model),            intent(in) :: M
        type(program_settings), intent(in) :: settings



        !> This is a very important array. live_data(:,i) constitutes the
        !! information in the ith live point in the unit hypercube:
        !! ( <-hypercube coordinates->, <-physical coordinates->, <-derived parameters->, likelihood)
        double precision, dimension(M%nTotal,settings%nlive) :: live_data

        ! The new-born baby point
        double precision,    dimension(M%nTotal)   :: baby_point
        ! The recently dead point
        double precision,    dimension(M%nTotal)   :: late_point

        ! Point to seed a new one from
        double precision,    dimension(M%nTotal)   :: seed_point

        ! temp variable for getting a random integer
        integer, dimension(1) :: point_number 

        double precision :: baby_likelihood
        double precision :: late_likelihood

        double precision, dimension(2) :: evidence_vec

        ! Means to be calculated
        double precision :: mean_likelihood_calls

        logical :: more_samples_needed

        integer :: ndead

        double precision,    dimension(M%nDims,2)   :: min_max_array

#ifdef MPI
        double precision, allocatable, dimension(:,:) :: live_data_local
        integer :: nprocs
        integer :: myrank
        integer :: nlive_local
        integer :: ierror
#endif

        !------- 1) Initialisation ---------------------------------
        ! Need to initialise
        !  * live_data
        !  * mean log likelihood to be passed to the evidence calculator
        !  * more_samples_needed
        !  * mean_likelihood_calls
        !  * ndead






#ifdef MPI
        nprocs = mpi_size()  ! Get the number of MPI procedures
        myrank = mpi_rank()  ! Get the MPI label of the current processor

        if(myrank==0) call write_opening_statement(M,settings)
#else
        call write_opening_statement(M,settings) 
#endif





#ifdef MPI
        if(myrank==0) call write_started_generating(settings%feedback)

        ! Create initial live points on all processors, and then merge them onto
        ! the root with MPI_GATHER

        ! First allocate a local live_data array which is nlive/nprocs on each
        ! of the nprocs nodes
        nlive_local = ceiling(settings%nlive/(nprocs+0d0))
        allocate(live_data_local(M%nTotal,nlive_local))

        ! Generate nlive/nprocs live points on each of the nprocs nodes
        live_data_local = GenerateLivePoints(M,nlive_local)

        ! Sort the live points in order of likelihood, first point lowest, last point highest on every node
        call quick_sort(live_data_local)

        ! Gather all of this data onto the root node
        call MPI_GATHER(          &  
            live_data_local,      & ! sending array
            M%nTotal*nlive_local, & ! number of elements to be sent
            MPI_DOUBLE_PRECISION, & ! type of element to be sent
            live_data,            & ! recieving array
            M%nTotal*nlive_local, & ! number of elements to be recieved from each node
            MPI_DOUBLE_PRECISION, & ! type of element recieved
            0,                    & ! root node address
            MPI_COMM_WORLD,       & ! communication info
            mpierror)               ! error (from module mpi_module)

        ! deallocate the now unused local live points array to save memory
        deallocate(live_data_local)

        ! Sort the live points in order of likelihood, first point lowest, last point highest on the root node
        ! (note that this is made easier by the fact that this array is semi-sorted
        if(myrank==0) call quick_sort(live_data)

        if(myrank==0) call write_finished_generating(settings%feedback) 
#else
        call write_started_generating(settings%feedback)

        ! Create initial live points
        live_data = GenerateLivePoints(M,settings%nlive)

        ! Sort them in order of likelihood, first point lowest, last point highest
        call quick_sort(live_data)

        call write_finished_generating(settings%feedback)
#endif



#ifdef MPI
        if (myrank>0) return
#endif


        ! definately more samples needed than this
        more_samples_needed = .true.

        ! Set the number of likelihood calls for each point to 1
        live_data(M%d0,:) = 1

        ! Set the initial trial values of the chords as the diagonal of the hypercube
        live_data(M%d0+1,:) = sqrt(M%nDims+0d0)

        ! Compute the average loglikelihood and hand it to the evidence calculator via the second argument,
        ! and pass the maximum likelihood value in the first argument
        ! (note the negative number of dead points in the third argument to trigger initialisation). 
        evidence_vec = settings%evidence_calculator(                                       &
            live_data(M%l0,settings%nlive),                          &
            logsumexp(live_data(M%l0,:)) - log(settings%nlive+0d0) , &
            -1,more_samples_needed)

        ! initialise the mean number of likelihood calls to 1
        mean_likelihood_calls = 1d0

        ! no dead points originally
        ndead = 0

        ! If we're saving the dead points, open the relevant file
        if (settings%save_dead) open(unit=222, file='dead_points.dat')

        call write_started_sampling(settings%feedback)



        do while ( more_samples_needed )

            ! update the minimum and maximum values of the live points
            min_max_array(:,1) = minval(live_data(M%h0:M%h1,:),2)
            min_max_array(:,2) = maxval(live_data(M%h0:M%h1,:),2)

            ! Record the point that's just died
            late_point = live_data(:,1)
            ndead = ndead + 1

            ! Get the likelihood contour
            late_likelihood = late_point(M%l0)

            ! Select a seed point for the generator
            !   - get a random number in [1,nlive-1]
            point_number = random_integers(1,settings%nlive-1) 
            !   - get this point from live_data  (excluding the possibility of drawing the late point)
            seed_point = live_data(:,1+point_number(1))

            ! Generate a new point within the likelihood bound of the late point
            baby_point = settings%sampler(seed_point, late_likelihood, min_max_array, M)
            baby_likelihood  = baby_point(M%l0)

            ! update the mean number of likelihood calls
            mean_likelihood_calls = mean_likelihood_calls + (baby_point(M%d0) - late_point(M%d0) ) / (settings%nlive + 0d0)

            ! Insert the new point
            call insert_baby_point(baby_point,live_data)

            ! Calculate the new evidence (and check to see if we're accurate enough)
            evidence_vec =  settings%evidence_calculator(baby_likelihood,late_likelihood,ndead,more_samples_needed)

            ! Halt if we've reached the desired maximum iterations
            if (settings%max_ndead >0 .and. ndead .ge. settings%max_ndead) more_samples_needed = .false.

            ! Write the dead points to a file if desired
            if (settings%save_dead) write(222,'(<M%nTotal+1>E17.9)') exp(ndead*log(settings%nlive/(settings%nlive+1d0))), late_point

            ! Feedback to command line every nlive iterations
            if (settings%feedback>=1 .and. mod(ndead,settings%nlive) .eq.0 ) then
                write(*,'("ndead     = ", I20                  )') ndead
                write(*,'("efficiency= ", F20.2                )') mean_likelihood_calls
                write(*,'("log(Z)    = ", F20.5, " +/- ", F12.5)') evidence_vec(1), exp(0.5*evidence_vec(2)-evidence_vec(1)) 
                write(*,*)
            end if
        end do


        ! close the dead points file if we're nearly done
        if (settings%save_dead) close(222)

        call write_final_results(M,evidence_vec,ndead,settings%feedback)

    end subroutine NestedSampling




    !> Generate an initial set of live points distributed uniformly in the unit hypercube
    function GenerateLivePoints(M,nlive) result(live_data)
        use model_module,    only: model, calculate_point
        use random_module,   only: random_reals
        use feedback_module, only: write_generating_live_points,write_started_generating,write_finished_generating
        implicit none

        !> The model details (loglikelihood, priors, ndims etc...)
        type(model), intent(in) :: M

        !> The number of points to be generated
        integer, intent(in) :: nlive

        !live_data(:,i) constitutes the information in the ith live point in the unit hypercube: 
        ! ( <-hypercube coordinates->, <-derived parameters->, likelihood)
        double precision, dimension(M%nTotal,nlive) :: live_data

        ! Loop variable
        integer i_live

        ! initialise live points at zero
        live_data = 0d0

        do i_live=1,nlive

            ! Generate a random coordinate
            live_data(:,i_live) = random_reals(M%nDims)

            ! Compute physical coordinates, likelihoods and derived parameters
            call calculate_point( M, live_data(:,i_live) )

        end do

    end function GenerateLivePoints



    !> Sort nlive vectors in data_array(:,nlive) by the last element of each
    !! vector
    recursive subroutine quick_sort(data_array)

        !> an array of nlive  (coord,derived,like) to be sorted by the
        !! likelihood value at the end of each vector
        double precision, dimension(:,:), intent(inout) :: data_array

        integer :: iq

        if( size(data_array, 2 ) > 1) then
            call partition(data_array,iq)
            call quick_sort( data_array(:,:iq-1) )
            call quick_sort( data_array(:,iq:)   )
        endif
        contains

        !> @todo comment this quick_sort partition
        subroutine partition(data_array, marker)

            double precision, intent(inout), dimension(:,:) :: data_array
            integer, intent(out) :: marker
            integer :: i, j
            double precision, dimension(size(data_array,1)) :: temp,x
            integer :: loglike_pos

            loglike_pos = size(data_array,1)

            x(:) = data_array(:,1)
            i= 0
            j= size( data_array, 2 ) + 1

            do
                j = j-1
                do
                    if (data_array(loglike_pos,j) <= x(loglike_pos)) exit
                    j = j-1
                end do

                i = i+1
                do
                    if (data_array(loglike_pos,i) >= x(loglike_pos)) exit
                    i = i+1
                end do

                if (i < j) then
                    ! exchange data_array(:,i) and data_array(:,j)
                    temp(:)         = data_array(:,i)
                    data_array(:,i) = data_array(:,j)
                    data_array(:,j) = temp(:)

                    elseif (i == j) then
                    marker = i+1
                    return
                else
                    marker = i
                    return
                endif
            end do

        end subroutine partition

    end subroutine quick_sort





    !> Insert the new point into the data array
    !!
    !! Since the data array is already sorted, one can insert a new point using
    !! binary search insertion algorithm, which is contained in here
    subroutine insert_baby_point(baby_point,data_array)
        double precision, intent(in),    dimension(:)   :: baby_point
        double precision, intent(inout), dimension(:,:) :: data_array

        double precision :: loglike 
        integer          :: loglike_pos
        integer          :: nlive

        integer :: baby_position

        loglike_pos = size(data_array,1)
        nlive       = size(data_array,2)

        loglike = baby_point(loglike_pos)

        if( loglike > data_array(loglike_pos,nlive) ) then
            baby_position = nlive
        else
            baby_position =  binary_search(1,nlive)
        end if

        ! Delete the lowest likelihood point by shifting the points in the data
        ! array from baby_position and below down by one
        data_array(:,1:baby_position-1) = data_array(:,2:baby_position)

        ! Add the new point
        data_array(:,baby_position) = baby_point(:)

        contains

        !> Binary search algorithm
        recursive function binary_search(imin,imax) result(baby_point_pos)
            integer, intent(in) :: imin
            integer, intent(in) :: imax

            integer :: baby_point_pos

            baby_point_pos = (imin + imax)/2

            if ( baby_point_pos == imin ) then
                return
            else if( data_array(loglike_pos,baby_point_pos) > loglike ) then
                ! baby_point in lower subset
                baby_point_pos = binary_search(imin,baby_point_pos)
            else 
                ! baby_point in upper subset
                baby_point_pos = binary_search(baby_point_pos,imax)
            end if

        end function binary_search

    end subroutine insert_baby_point















end module nested_sampling_module
