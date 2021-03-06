module med_phases_aofluxes_mod

  use med_kind_mod          , only : CX=>SHR_KIND_CX, CS=>SHR_KIND_CS, CL=>SHR_KIND_CL, R8=>SHR_KIND_R8
  use med_internalstate_mod , only : InternalState
  use med_internalstate_mod , only : mastertask, logunit
  use med_constants_mod     , only : dbug_flag    => med_constants_dbug_flag
  use med_utils_mod         , only : memcheck     => med_memcheck
  use med_utils_mod         , only : chkerr       => med_utils_chkerr
  use med_methods_mod       , only : FB_fldchk    => med_methods_FB_FldChk
  use med_methods_mod       , only : FB_GetFldPtr => med_methods_FB_GetFldPtr
  use med_methods_mod       , only : FB_diagnose  => med_methods_FB_diagnose
  use med_map_mod           , only : med_map_field_packed
  use perf_mod              , only : t_startf, t_stopf

  implicit none
  private

  !--------------------------------------------------------------------------
  ! Public routines
  !--------------------------------------------------------------------------

  public  :: med_phases_aofluxes_run

  !--------------------------------------------------------------------------
  ! Private routines
  !--------------------------------------------------------------------------

  private :: med_aofluxes_init
  private :: med_aofluxes_run

  !--------------------------------------------------------------------------
  ! Private data
  !--------------------------------------------------------------------------

  type aoflux_type
     integer  , pointer :: mask        (:) => null() ! ocn domain mask: 0 <=> inactive cell
     real(R8) , pointer :: rmask       (:) => null() ! ocn domain mask: 0 <=> inactive cell
     real(R8) , pointer :: lats        (:) => null() ! latitudes  (degrees)
     real(R8) , pointer :: lons        (:) => null() ! longitudes (degrees)
     real(R8) , pointer :: uocn        (:) => null() ! ocn velocity, zonal
     real(R8) , pointer :: vocn        (:) => null() ! ocn velocity, meridional
     real(R8) , pointer :: tocn        (:) => null() ! ocean temperature
     real(R8) , pointer :: zbot        (:) => null() ! atm level height
     real(R8) , pointer :: ubot        (:) => null() ! atm velocity, zonal
     real(R8) , pointer :: vbot        (:) => null() ! atm velocity, meridional
     real(R8) , pointer :: thbot       (:) => null() ! atm potential T
     real(R8) , pointer :: shum        (:) => null() ! atm specific humidity
     real(R8) , pointer :: shum_16O    (:) => null() ! atm H2O tracer
     real(R8) , pointer :: shum_HDO    (:) => null() ! atm HDO tracer
     real(R8) , pointer :: shum_18O    (:) => null() ! atm H218O tracer
     real(R8) , pointer :: roce_16O    (:) => null() ! ocn H2O ratio
     real(R8) , pointer :: roce_HDO    (:) => null() ! ocn HDO ratio
     real(R8) , pointer :: roce_18O    (:) => null() ! ocn H218O ratio
     real(R8) , pointer :: pbot        (:) => null() ! atm bottom pressure
     real(R8) , pointer :: dens        (:) => null() ! atm bottom density
     real(R8) , pointer :: tbot        (:) => null() ! atm bottom surface T
     real(R8) , pointer :: sen         (:) => null() ! heat flux: sensible
     real(R8) , pointer :: lat         (:) => null() ! heat flux: latent
     real(R8) , pointer :: lwup        (:) => null() ! lwup over ocean
     real(R8) , pointer :: evap        (:) => null() ! water flux: evaporation
     real(R8) , pointer :: evap_16O    (:) => null() ! H2O flux: evaporation
     real(R8) , pointer :: evap_HDO    (:) => null() ! HDO flux: evaporation
     real(R8) , pointer :: evap_18O    (:) => null() ! H218O flux: evaporation
     real(R8) , pointer :: taux        (:) => null() ! wind stress, zonal
     real(R8) , pointer :: tauy        (:) => null() ! wind stress, meridional
     real(R8) , pointer :: tref        (:) => null() ! diagnostic:  2m ref T
     real(R8) , pointer :: qref        (:) => null() ! diagnostic:  2m ref Q
     real(R8) , pointer :: u10         (:) => null() ! diagnostic: 10m wind speed
     real(R8) , pointer :: duu10n      (:) => null() ! diagnostic: 10m wind speed squared
     real(R8) , pointer :: lwdn        (:) => null() ! long  wave, downward
     real(R8) , pointer :: ustar       (:) => null() ! saved ustar
     real(R8) , pointer :: re          (:) => null() ! saved re
     real(R8) , pointer :: ssq         (:) => null() ! saved sq
     logical            :: created         ! has this data type been created
  end type aoflux_type

  ! The following three variables are obtained as attributes from gcomp
  logical       :: flds_wiso  ! use case
  logical       :: compute_atm_dens
  logical       :: compute_atm_thbot
  character(*), parameter :: u_FILE_u = &
       __FILE__

!================================================================================
contains
!================================================================================

  subroutine med_phases_aofluxes_run(gcomp, rc)

    use ESMF     , only : ESMF_GridComp, ESMF_Clock, ESMF_GridCompGet
    use ESMF     , only : ESMF_LogWrite, ESMF_LOGMSG_INFO, ESMF_SUCCESS
    use ESMF     , only : ESMF_FieldBundleIsCreated
    use NUOPC    , only : NUOPC_IsConnected, NUOPC_CompAttributeGet
    use esmFlds  , only : med_fldList_GetNumFlds, med_fldList_GetFldNames
    use esmFlds  , only : fldListFr, fldListMed_aoflux, compatm, compocn, compname
    use NUOPC    , only : NUOPC_CompAttributeGet

    !-----------------------------------------------------------------------
    ! Compute atm/ocn fluxes
    !-----------------------------------------------------------------------

    ! input/output variables
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    ! local variables
    type(InternalState)     :: is_local
    type(aoflux_type), save :: aoflux
    logical, save           :: first_call = .true.
    character(len=*),parameter :: subname='(med_phases_aofluxes)'
    !---------------------------------------

    rc = ESMF_SUCCESS

    ! Get the internal state from the mediator Component.
    nullify(is_local%wrap)
    call ESMF_GridCompGetInternalState(gcomp, is_local, rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    if (first_call) then
       ! If field bundles have been created for the ocean/atmosphere flux computation
       if ( ESMF_FieldBundleIsCreated(is_local%wrap%FBMed_aoflux_a, rc=rc) .and. &
            ESMF_FieldBundleIsCreated(is_local%wrap%FBMed_aoflux_o, rc=rc)) then

          ! Allocate memoroy for the aoflux module data type (mediator atm/ocn field bundle on the ocean grid)
          call med_aofluxes_init(gcomp, aoflux, &
               FBAtm=is_local%wrap%FBImp(compatm,compocn), &
               FBOcn=is_local%wrap%FBImp(compocn,compocn), &
               FBFrac=is_local%wrap%FBfrac(compocn), &
               FBMed_aoflux=is_local%wrap%FBMed_aoflux_o, rc=rc)
          if (chkerr(rc,__LINE__,u_FILE_u)) return
          aoflux%created = .true.
       else
          aoflux%created = .false.
       end if

       ! Now set first_call to .false.
       first_call = .false.
    end if

    ! Return if there is no aoflux has not been created
    if (.not. aoflux%created) then
       RETURN
    end if

    ! Start time timer
    call t_startf('MED:'//subname)

    if (dbug_flag > 5) then
       call ESMF_LogWrite(trim(subname)//": called", ESMF_LOGMSG_INFO)
    endif

    call memcheck(subname, 5, mastertask)

    ! TODO(mvertens, 2019-01-12): ONLY regrid atm import fields that are needed for the atm/ocn flux calculation
    ! Regrid atm import field bundle from atm to ocn grid as input for ocn/atm flux calculation
    call med_map_field_packed( &
         FBSrc=is_local%wrap%FBImp(compatm,compatm), &
         FBDst=is_local%wrap%FBImp(compatm,compocn), &
         FBFracSrc=is_local%wrap%FBFrac(compatm), &
         field_normOne=is_local%wrap%field_normOne(compatm,compocn,:), &
         packed_data=is_local%wrap%packed_data(compatm,compocn,:), &
         routehandles=is_local%wrap%RH(compatm,compocn,:), rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    ! Calculate atm/ocn fluxes on the destination grid
    call med_aofluxes_run(gcomp, aoflux, rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    if (dbug_flag > 1) then
       call FB_diagnose(is_local%wrap%FBMed_aoflux_o, &
            string=trim(subname) //' FBAMed_aoflux_o' , rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
    end if

    call t_stopf('MED:'//subname)

  end subroutine med_phases_aofluxes_run

!================================================================================

  subroutine med_aofluxes_init(gcomp, aoflux, FBAtm, FBOcn, FBFrac, FBMed_aoflux, rc)

    use ESMF     , only : ESMF_LogWrite, ESMF_LOGMSG_INFO, ESMF_LogFoundError
    use ESMF     , only : ESMF_SUCCESS, ESMF_LOGERR_PASSTHRU
    use ESMF     , only : ESMF_GridComp, ESMF_GridCompGet, ESMF_VM
    use ESMF     , only : ESMF_Field, ESMF_FieldGet, ESMF_FieldBundle, ESMF_VMGet
    use NUOPC    , only : NUOPC_CompAttributeGet
    use shr_flux_mod  , only :  shr_flux_adjust_constants
    !-----------------------------------------------------------------------
    ! Initialize pointers to the module variables
    !-----------------------------------------------------------------------

    ! input/output variables
    type(ESMF_GridComp)                    :: gcomp
    type(aoflux_type)      , intent(inout) :: aoflux
    type(ESMF_FieldBundle) , intent(in)    :: FBAtm               ! Atm Import fields on aoflux grid
    type(ESMF_FieldBundle) , intent(in)    :: FBOcn               ! Ocn Import fields on aoflux grid
    type(ESMF_FieldBundle) , intent(in)    :: FBfrac              ! Fraction data for various components, on their grid
    type(ESMF_FieldBundle) , intent(inout) :: FBMed_aoflux        ! Ocn albedos computed in mediator
    integer                , intent(out)   :: rc

    ! local variables
    integer                  :: iam
    integer                  :: n
    integer                  :: lsize
    real(R8), pointer        :: ofrac(:) => null()
    real(R8), pointer        :: ifrac(:) => null()
    character(CL)            :: cvalue
    logical                  :: flds_wiso  ! use case
    character(len=CX)        :: tmpstr
    real(R8)                :: flux_convergence        ! convergence criteria for imlicit flux computation
    integer                 :: flux_max_iteration      ! maximum number of iterations for convergence
    logical                 :: coldair_outbreak_mod    ! cold air outbreak adjustment  (Mahrt & Sun 1995,MWR)
    logical                 :: isPresent, isSet
    character(*),parameter   :: subName =   '(med_aofluxes_init) '
    !-----------------------------------------------------------------------

    if (dbug_flag > 5) then
      call ESMF_LogWrite(trim(subname)//": called", ESMF_LOGMSG_INFO)
    endif
    rc = ESMF_SUCCESS
    call memcheck(subname, 5, mastertask)

    call t_startf('MED:'//subname)

    !----------------------------------
    ! get attributes that are set as module variables
    !----------------------------------

    call NUOPC_CompAttributeGet(gcomp, name='flds_wiso', value=cvalue, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, line=__LINE__, file=__FILE__)) return
    read(cvalue,*) flds_wiso

    !----------------------------------
    ! atm/ocn fields
    !----------------------------------

    call FB_GetFldPtr(FBMed_aoflux, fldname='So_tref', fldptr1=aoflux%tref, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBMed_aoflux, fldname='So_qref', fldptr1=aoflux%qref, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBMed_aoflux, fldname='So_ustar', fldptr1=aoflux%ustar, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBMed_aoflux, fldname='So_re', fldptr1=aoflux%re, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBMed_aoflux, fldname='So_ssq', fldptr1=aoflux%ssq, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBMed_aoflux, fldname='So_u10', fldptr1=aoflux%u10, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBMed_aoflux, fldname='So_duu10n', fldptr1=aoflux%duu10n, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    call FB_GetFldPtr(FBMed_aoflux, fldname='Faox_taux', fldptr1=aoflux%taux, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBMed_aoflux, fldname='Faox_tauy', fldptr1=aoflux%tauy, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBMed_aoflux, fldname='Faox_lat', fldptr1=aoflux%lat, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBMed_aoflux, fldname='Faox_sen', fldptr1=aoflux%sen, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBMed_aoflux, fldname='Faox_evap', fldptr1=aoflux%evap, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    lsize = size(aoflux%evap)
    if (flds_wiso) then
       call FB_GetFldPtr(FBMed_aoflux, fldname='Faox_evap_16O', fldptr1=aoflux%evap_16O, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
       call FB_GetFldPtr(FBMed_aoflux, fldname='Faox_evap_18O', fldptr1=aoflux%evap_18O, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
       call FB_GetFldPtr(FBMed_aoflux, fldname='Faox_evap_HDO', fldptr1=aoflux%evap_HDO, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
    else
       allocate(aoflux%evap_16O(lsize)); aoflux%evap_16O(:) = 0._R8
       allocate(aoflux%evap_18O(lsize)); aoflux%evap_18O(:) = 0._R8
       allocate(aoflux%evap_HDO(lsize)); aoflux%evap_HDO(:) = 0._R8
    end if

    call FB_GetFldPtr(FBMed_aoflux, fldname='Faox_lwup', fldptr1=aoflux%lwup, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    !----------------------------------
    ! Ocn import fields
    !----------------------------------

    call FB_GetFldPtr(FBOcn, fldname='So_omask', fldptr1=aoflux%rmask, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBOcn, fldname='So_t', fldptr1=aoflux%tocn, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBOcn, fldname='So_u', fldptr1=aoflux%uocn, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBOcn, fldname='So_v', fldptr1=aoflux%vocn, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    if (flds_wiso) then
       call FB_GetFldPtr(FBOcn, fldname='So_roce_16O', fldptr1=aoflux%roce_16O, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
       call FB_GetFldPtr(FBOcn, fldname='So_roce_18O', fldptr1=aoflux%roce_18O, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
       call FB_GetFldPtr(FBOcn, fldname='So_roce_HDO', fldptr1=aoflux%roce_HDO, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
    else
       allocate(aoflux%roce_16O(lsize)); aoflux%roce_16O(:) = 0._R8
       allocate(aoflux%roce_18O(lsize)); aoflux%roce_18O(:) = 0._R8
       allocate(aoflux%roce_HDO(lsize)); aoflux%roce_HDO(:) = 0._R8
    end if

    !----------------------------------
    ! Atm import fields
    !----------------------------------

    call FB_GetFldPtr(FBAtm, fldname='Sa_z', fldptr1=aoflux%zbot, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBAtm, fldname='Sa_u', fldptr1=aoflux%ubot, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBAtm, fldname='Sa_v', fldptr1=aoflux%vbot, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    call FB_GetFldPtr(FBAtm, fldname='Sa_tbot', fldptr1=aoflux%tbot, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return

    ! bottom level potential temperature will need to be computed if not received from the atm
    if (FB_fldchk(FBAtm, 'Sa_ptem', rc=rc)) then
       call FB_GetFldPtr(FBAtm, fldname='Sa_ptem', fldptr1=aoflux%thbot, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
       compute_atm_thbot = .false.
    else
       allocate(aoflux%thbot(lsize))
       compute_atm_thbot = .true.
    end if

    ! bottom level density will need to be computed if not received from the atm
    if (FB_fldchk(FBAtm, 'Sa_dens', rc=rc)) then
       call FB_GetFldPtr(FBAtm, fldname='Sa_dens', fldptr1=aoflux%dens, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
       compute_atm_dens = .false.
    else
       compute_atm_dens = .true.
       allocate(aoflux%dens(lsize))
    end if

    ! if either density or potential temperature are computed, will need bottom level pressure
    if (compute_atm_dens .or. compute_atm_thbot) then
       call FB_GetFldPtr(FBAtm, fldname='Sa_pbot', fldptr1=aoflux%pbot, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
    end if

    call FB_GetFldPtr(FBAtm, fldname='Sa_shum', fldptr1=aoflux%shum, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    if (flds_wiso) then
       call FB_GetFldPtr(FBAtm, fldname='Sa_shum_16O', fldptr1=aoflux%shum_16O, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
       call FB_GetFldPtr(FBAtm, fldname='Sa_shum_18O', fldptr1=aoflux%shum_18O, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
       call FB_GetFldPtr(FBAtm, fldname='Sa_shum_HDO', fldptr1=aoflux%shum_HDO, rc=rc)
       if (chkerr(rc,__LINE__,u_FILE_u)) return
    else
       allocate(aoflux%shum_16O(lsize)); aoflux%shum_16O(:) = 0._R8
       allocate(aoflux%shum_18O(lsize)); aoflux%shum_18O(:) = 0._R8
       allocate(aoflux%shum_HDO(lsize)); aoflux%shum_HDO(:) = 0._R8
    end if

    !----------------------------------
    ! setup the compute mask.
    !----------------------------------

    ! allocate grid mask fields
    ! default compute everywhere, then "turn off" gridcells
    allocate(aoflux%mask(lsize))
    aoflux%mask(:) = 1

    write(tmpstr,'(i12,g22.12,i12)') lsize,sum(aoflux%rmask),sum(aoflux%mask)
    call ESMF_LogWrite(trim(subname)//" : maskA= "//trim(tmpstr), ESMF_LOGMSG_INFO)

    where (aoflux%rmask(:) == 0._R8) aoflux%mask(:) = 0   ! like nint

    write(tmpstr,'(i12,g22.12,i12)') lsize,sum(aoflux%rmask),sum(aoflux%mask)
    call ESMF_LogWrite(trim(subname)//" : maskB= "//trim(tmpstr), ESMF_LOGMSG_INFO)

    ! TODO: need to check if this logic is correct
    ! then check ofrac + ifrac
    ! call FB_getFldPtr(FBFrac , fldname='ofrac' , fldptr1=ofrac, rc=rc)
    ! if (chkerr(rc,__LINE__,u_FILE_u)) return
    ! call FB_getFldPtr(FBFrac , fldname='ifrac' , fldptr1=ifrac, rc=rc)
    ! if (chkerr(rc,__LINE__,u_FILE_u)) return
    ! where (ofrac(:) + ifrac(:) <= 0.0_R8) mask(:) = 0
    !----------------------------------
    ! Get config variables on first call
    !----------------------------------

    call NUOPC_CompAttributeGet(gcomp, name='coldair_outbreak_mod', value=cvalue, isPresent=isPresent, isSet=isSet, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    if (isPresent .and. isSet) then
       read(cvalue,*) coldair_outbreak_mod
    else
       coldair_outbreak_mod = .false.
    end if

    call NUOPC_CompAttributeGet(gcomp, name='flux_max_iteration', value=cvalue, isPresent=isPresent, isSet=isSet, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    if (isPresent .and. isSet) then
       read(cvalue,*) flux_max_iteration
    else
       flux_max_iteration = 1
    end if

    call NUOPC_CompAttributeGet(gcomp, name='flux_convergence', value=cvalue, isPresent=isPresent, isSet=isSet, rc=rc)
    if (chkerr(rc,__LINE__,u_FILE_u)) return
    if (isPresent .and. isSet) then
       read(cvalue,*) flux_convergence
    else
       flux_convergence = 0.0_r8
    end if

    call shr_flux_adjust_constants(&
         flux_convergence_tolerance=flux_convergence, &
         flux_convergence_max_iteration=flux_max_iteration, &
         coldair_outbreak_mod=coldair_outbreak_mod)



    if (dbug_flag > 5) then
      call ESMF_LogWrite(trim(subname)//": done", ESMF_LOGMSG_INFO)
    endif
    call t_stopf('MED:'//subname)

  end subroutine med_aofluxes_init

!===============================================================================

  subroutine med_aofluxes_run(gcomp, aoflux, rc)

    use ESMF          , only : ESMF_GridComp, ESMF_Clock, ESMF_Time, ESMF_TimeInterval
    use ESMF          , only : ESMF_GridCompGet, ESMF_ClockGet, ESMF_TimeGet, ESMF_TimeIntervalGet
    use ESMF          , only : ESMF_LogWrite, ESMF_LogMsg_Info
    use NUOPC         , only : NUOPC_CompAttributeGet
    use shr_flux_mod  , only : shr_flux_atmocn

    !-----------------------------------------------------------------------
    ! Determine atm/ocn fluxes eother on atm or on ocean grid
    ! The module arrays are set via pointers the the mediator internal states
    ! in med_ocnatm_init and are used below.
    !-----------------------------------------------------------------------

    ! Arguments
    type(ESMF_GridComp)               :: gcomp
    type(aoflux_type) , intent(inout) :: aoflux
    integer           , intent(out)   :: rc
    !
    ! Local variables
    character(CL)           :: cvalue
    integer                 :: n,i                     ! indices
    integer                 :: lsize                   ! local size
    character(len=CX)       :: tmpstr
    logical                 :: isPresent, isSet
    character(*),parameter  :: subName = '(med_aofluxes_run) '
    !-----------------------------------------------------------------------

    call t_startf('MED:'//subname)


    !----------------------------------
    ! Determine the compute mask
    !----------------------------------

    ! Prefer to compute just where ocean exists, so setup a mask here.
    ! this could be run with either the ocean or atm grid so need to be careful.
    ! really want the ocean mask on ocean grid or ocean mask mapped to atm grid,
    ! but do not have access to the ocean mask mapped to the atm grid.
    ! the dom mask is a good place to start, on ocean grid, it should be what we want,
    ! on the atm grid, it's just all 1's so not very useful.
    ! next look at ofrac+ifrac in fractions.  want to compute on all non-land points.
    ! using ofrac alone will exclude points that are currently all sea ice but that later
    ! could be less that 100% covered in ice.

    lsize = size(aoflux%mask)

    write(tmpstr,'(i12,g22.12,i12)') lsize,sum(aoflux%rmask),sum(aoflux%mask)
    call ESMF_LogWrite(trim(subname)//" : maskA= "//trim(tmpstr), ESMF_LOGMSG_INFO)

    aoflux%mask(:) = 1
    where (aoflux%rmask(:) == 0._R8) aoflux%mask(:) = 0   ! like nint

    write(tmpstr,'(i12,g22.12,i12)') lsize,sum(aoflux%rmask),sum(aoflux%mask)
    call ESMF_LogWrite(trim(subname)//" : maskB= "//trim(tmpstr), ESMF_LOGMSG_INFO)

    write(tmpstr,'(3i12)') lsize,size(aoflux%mask),sum(aoflux%mask)
    call ESMF_LogWrite(trim(subname)//" : mask= "//trim(tmpstr), ESMF_LOGMSG_INFO)

    !----------------------------------
    ! Update atmosphere/ocean surface fluxes
    !----------------------------------

    if (compute_atm_thbot) then
       do n = 1,lsize
          if (aoflux%mask(n) /= 0._r8) then
             aoflux%thbot(n) = aoflux%tbot(n)*((100000._R8/aoflux%pbot(n))**0.286_R8)
          end if
       end do
    end if
    if (compute_atm_dens) then
       do n = 1,lsize
          if (aoflux%mask(n) /= 0._r8) then
             aoflux%dens(n) = aoflux%pbot(n)/(287.058_R8*(1._R8 + 0.608_R8*aoflux%shum(n))*aoflux%tbot(n))
          end if
       end do
    end if

    ! TODO(mvertens, 2019-10-30): remove the hard-wiring of minwind and replace it with namelist input
    call shr_flux_atmocn (&
         nMax=lsize, zbot=aoflux%zbot, ubot=aoflux%ubot, vbot=aoflux%vbot, thbot=aoflux%thbot, &
         qbot=aoflux%shum, s16O=aoflux%shum_16O, sHDO=aoflux%shum_HDO, s18O=aoflux%shum_18O, rbot=aoflux%dens, &
         tbot=aoflux%tbot, us=aoflux%uocn, vs=aoflux%vocn, &
         ts=aoflux%tocn, mask=aoflux%mask, seq_flux_atmocn_minwind=0.5_r8, &
         sen=aoflux%sen, lat=aoflux%lat, lwup=aoflux%lwup, &
         r16O=aoflux%roce_16O, rhdo=aoflux%roce_HDO, r18O=aoflux%roce_18O, &
         evap=aoflux%evap, evap_16O=aoflux%evap_16O, evap_HDO=aoflux%evap_HDO, evap_18O=aoflux%evap_18O, &
         taux=aoflux%taux, tauy=aoflux%tauy, tref=aoflux%tref, qref=aoflux%qref, &
         ocn_surface_flux_scheme=0, &
         duu10n=aoflux%duu10n, ustar_sv=aoflux%ustar, re_sv=aoflux%re, ssq_sv=aoflux%ssq, &
         missval = 0.0_r8)

    do n = 1,lsize
       if (aoflux%mask(n) /= 0) then
          aoflux%u10(n) = sqrt(aoflux%duu10n(n))
       end if
    enddo
    call t_stopf('MED:'//subname)

  end subroutine med_aofluxes_run

end module med_phases_aofluxes_mod
