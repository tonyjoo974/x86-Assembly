
.data					# section declaration

        # Useful offset constants for accessing members of a 
        # struct mp1_blink_struct structure
        LOCATION   = 0    
        ON_CHAR    = 2
        OFF_CHAR   = 3 
        ON_LENGTH  = 4
        OFF_LENGTH = 6
        COUNTDOWN  = 8
        STATUS     = 10
        NEXT       = 12

        STRUCT_SIZE = 16

        LOCATION_CAP = 2000
# Pointer to head of list (initialized to NULL)
mp1_list_head:
        .long   0

jump_table:
        .long   mp1_ioctl_add
        .long   mp1_ioctl_remove
        .long   mp1_ioctl_find
        .long   mp1_ioctl_sync

.text					# section declaration

# Export the function symbol names

.global mp1_rtc_tasklet
.global mp1_ioctl

# void mp1_poke(void);
#
# Interface: Register-based arguments (not C-style)
#    Inputs: %cl  - The byte you wish to write
#            %eax - Offset from the start of video memory that you wish
#                   to write to
#   Outputs: Text-mode video screen is written to at location %eax with
#            the byte in %cl
# Registers: Clobbers EDX
mp1_poke:
        
	movl    vmem_base_addr(,1),%edx
	movb    %cl,(%edx,%eax,1)
	ret

# void mp1_rtc_tasklet(unsigned long);
# Interface: Update the state of the game
# Inputs   : None
# Outputs  : None
mp1_rtc_tasklet:
	pushl	%ebp			# save old EBP
	movl	%esp, %ebp		# update stack pointer

	pushl	%ebx			# save callee-saved
	pushl	%edi
	pushl	%esi

        # ebx = mp1_list_head
        movl    mp1_list_head, %ebx
        # check for null head ptr
        cmpl    $0, %ebx
        je      restore_reg

while_next_not_null:
        # decrement countdown
        decw    COUNTDOWN(%ebx)
        cmpw    $0, COUNTDOWN(%ebx)
        jne     go_next_list

        # Check the status
        cmpw    $0, STATUS(%ebx)
        je      status_off

        # put the opposite character (i.e. interchange the status
        # between on/off) out to video memory with a call to mp1 poke
        movzwl  LOCATION(%ebx), %eax
        shll    $1,%eax        
        movb    OFF_CHAR(%ebx), %cl
        call    mp1_poke
        movw    OFF_LENGTH(%ebx),%ax
        movw    %ax, COUNTDOWN(%ebx)
        movw    $0, STATUS(%ebx)
        jmp     go_next_list    

status_off:
        # put the opposite character (i.e. interchange the status
        # between on/off) out to video memory with a call to mp1 poke
        movzwl  LOCATION(%ebx), %eax
        shll    $1,%eax
        movb    ON_CHAR(%ebx), %cl
        call    mp1_poke
        movw    ON_LENGTH(%ebx),%ax
        movw    %ax, COUNTDOWN(%ebx)
        movw    $1, STATUS(%ebx) 

go_next_list:
        # go back to while loop if next not null
        cmpl    $0, NEXT(%ebx)
        je      restore_reg
        movl    NEXT(%ebx), %ebx
        jmp     while_next_not_null


# int mp1_ioctl(unsigned long arg, unsigned int cmd);
# Interface: The dispatcher for the MP1 ioctls
# Inputs   : unsigned long arg - argument of mp1_ioctl
#          : unsigned int cmd  - function to be executed in mp1_ioctl
# Outputs  : integer number of ioctl function
mp1_ioctl:
        # EAX <- cmd
        movl    8(%esp), %eax
        # Check for any invalid cmd
	cmpl    $3, %eax
	ja      invalid_cmd
	cmpl    $0, %eax
	jb      invalid_cmd
        # M[jump_table + EAX * 4]
        jmp     *jump_table(,%eax,4)  

invalid_cmd: 
        # return -1
	movl    $-1, %eax 
	ret

# int mp1_ioctl_add(unsigned long arg)
# Interface: Adds a blinking location
# Inputs   : unsigned long arg - user-level pointer to mp1_blink_struct
# Outputs  : 0 for success; -1 for failure
mp1_ioctl_add:
	pushl	%ebp			# save old EBP
	movl	%esp, %ebp		# update stack pointer

	pushl	%ebx			# save callee-saved
	pushl	%edi
	pushl	%esi

        # check for null user-level ptr to structure
        cmpl    $0, 8(%ebp) 			
	je      null_handler	

        # dynamically allocate memory for structure
	pushl   $STRUCT_SIZE 		
	call    mp1_malloc
        addl    $4, %esp				
	cmpl	$0, %eax				
	je      go_error 				

        # edi = newly-allocated memory
	movl    %eax, %edi				

        # Copy the entire mp1_blink_struct from the user-space structure
        # to the newly-allocated memory
	pushl   $STRUCT_SIZE 			
	pushl   8(%ebp) 				
	pushl   %edi 				
	call    mp1_copy_from_user 	
	addl    $12, %esp 			

        # Check errors from mp1_copy_from_user	
	cmpl	$0, %eax				
	jne     go_error 			
	
        # Check if Location is valid
	cmpw    $LOCATION_CAP, LOCATION(%edi)			 	
	jae     go_error

        # insert the structure at the head of the linked list 			
	movl    mp1_list_head, %ebx 	
	movl    %ebx, NEXT(%edi)	
        movl    %edi, mp1_list_head

        # struct.countdown = struct.on_length
	movw    ON_LENGTH(%edi), %ax	
	movw    %ax, COUNTDOWN(%edi) 		
        # struct.status = 1
        movw    $1, STATUS(%edi) 		
	
        # call mp1_poke for displaying characters
        movzwl  LOCATION(%edi),%eax
        shll    $1,%eax
        movb    ON_CHAR(%edi),%cl
	call    mp1_poke 			
        movl    $0, %eax
        jmp     restore_reg

go_error:
        # free memory and return -1
	pushl   %eax 
	call    mp1_free
        addl    $4, %esp 				
	jmp     null_handler


# int mp1_ioctl_find(unsigned long arg)
# Interface: find the list for an element that matches the location
# Inputs   : unsigned long arg - user-level pointer to mp1_blink_struct
# Outputs  : 0 for success; -1 for failure        
mp1_ioctl_find:
	pushl	%ebp			# save old EBP
	movl	%esp, %ebp		# update stack pointer

	pushl	%ebx			# save callee-saved
	pushl	%edi
	pushl	%esi

        # check for null user-level ptr to structure
        movl    8(%ebp), %esi
        cmpl    $0, %esi
        jne     is_valid		
        jmp     null_handler

is_valid:
        movl    mp1_list_head, %ebx
        # check for null head ptr
        cmpl    $0, %ebx
        jg      while_not_end
        jmp     null_handler

while_not_end:
        # Check the location
        movw    LOCATION(%esi), %dx
        cmpw    $LOCATION_CAP, %dx
        jae     null_handler
        movw    LOCATION(%ebx), %cx    
        cmpw    %dx, %cx
        jne     go_next_node     

        # call copy_to_user
	pushl   $STRUCT_SIZE 			
	pushl   %ebx 				
	pushl   %esi 				
	call    mp1_copy_to_user 	
	addl    $12, %esp 			

        # Check errors from mp1_copy_to_user	
	cmpl	$0, %eax				
	je      restore_reg             
        jmp     null_handler

go_next_node:
        # go back to while loop if next not null
        cmpl    $0, NEXT(%ebx)
        je      null_handler
        movl    NEXT(%ebx), %ebx
        jmp     while_next_not_null


# int mp1_ioctl_sync(unsigned long arg)
# Interface: synchronize the two locations on the screen
# Inputs   : unsigned long arg consists of two short(16bits) locations 
# given: ebx = 1111 2222
# second: bx = 2222
#        edi = 0000 1111
# first:  di = 1111
# Outputs  : 0 for success; -1 for failure 
mp1_ioctl_sync:
	pushl	%ebp			# save old EBP
	movl	%esp, %ebp		# update stack pointer

	pushl	%ebx			# save callee-saved
	pushl	%edi
	pushl	%esi
        
        # separate the two locations from 32bits
        movl    8(%ebp), %ebx
        movl    8(%ebp), %edi
        shr     $16, %edi

        # check for validity
        cmpw    $LOCATION_CAP, %di
        jae     null_handler
        cmpw    $LOCATION_CAP, %bx
        jae     null_handler

        # search for the list that matches the first location
        pushl   %edi                    # param = first struct
        call    function_traversal
	addl    $4, %esp                    

        # check for error return value
        cmpl    $-1, %eax
        je      restore_reg
        # edx = linked list of first location
        movl    %eax, %edx

        # search for the list that matches the second location
        pushl   %ebx
        call    function_traversal
        addl    $4, %esp

        # check for error return value
        cmpl    $-1, %eax
        je      restore_reg
        # save return value(second element) to esi
        movl    %eax, %esi
        # copy the timing info from first element to second element
        xorl    %ebx, %ebx
        movw    ON_LENGTH(%edx), %bx
        movw    %bx, ON_LENGTH(%esi)
        movw    OFF_LENGTH(%edx), %bx
        movw    %bx, OFF_LENGTH(%esi)
        movw    COUNTDOWN(%edx), %bx
        movw    %bx, COUNTDOWN(%esi)
        movw    STATUS(%edx), %bx
        movw    %bx, STATUS(%esi)

        # display character to screen
        movzwl  LOCATION(%esi), %eax
        shl     $1,%eax
        cmpw    $0, %bx
        je      display_off_char
        movb    ON_CHAR(%esi), %cl
        call    mp1_poke
        
display_off_char:
        # display character to screen
        movb    OFF_CHAR(%esi), %cl
        call    mp1_poke
        movl    $0, %eax
        jmp     restore_reg

# int mp1_ioctl_remove(unsigned long arg)
# Interface: remove the corresponding location
# Inputs   : unsigned long arg - integer of location
# Outputs  : 0 for success; -1 for failure                  
mp1_ioctl_remove:
	pushl	%ebp			# save old EBP
	movl	%esp, %ebp		# update stack pointer

        pushl   %ecx

	pushl	%ebx			# save callee-saved
	pushl	%edi
	pushl	%esi
        # edi = location param
        movw    8(%ebp), %di
        # check if head is null
        movl    mp1_list_head, %ebx        
        cmpl    $0, %ebx
        je      remove_fail
        # position(ecx) = 0; i(esi) = 0;
        xorl    %ecx, %ecx
        xorl    %esi, %esi
        # node to delete is head node
        cmpw    LOCATION(%ebx), %di
        jne     delete_middle_node
        movl    NEXT(%ebx), %eax
        movl    %eax, mp1_list_head
        pushl   %ebx
        call    mp1_free
        movl    $0, %eax
        jmp     restore_reg

delete_middle_node:
        # node to delete is middle node
        cmpw    LOCATION(%ebx), %di
        jne     go_to_next
        movl    mp1_list_head, %ebx
        subl    $1, %ecx    
for_loop:
        cmpl    %ecx, %esi
        jae     found_prev
        movl    NEXT(%ebx), %ebx
        inc     %esi
        jmp     for_loop

found_prev:     
        # node = curr->next
        movl    NEXT(%ebx), %ecx
        movl    NEXT(%ecx), %ecx
        # movl    $0, NEXT(%ebx)
        movl    NEXT(%ebx), %eax
        pushl   %eax
        call    mp1_free
        movl    %ecx, NEXT(%ebx)
        movl    $0, %eax
        jmp     remove_exit

go_to_next:
        inc     %ecx
        cmpl    $0, NEXT(%ebx)
        je      remove_fail        
        movl    NEXT(%ebx), %ebx
        jmp     delete_middle_node

remove_fail:
        movl    $-1, %eax
remove_exit:
        popl    %esi		
	popl    %edi
	popl    %ebx
        popl    %ecx

        leave        
	ret


#                    #
# /Helper functions/ #
#                    #
function_traversal:
	pushl	%ebp			# save old EBP
	movl	%esp, %ebp		# update stack pointer

	pushl	%ebx			# save callee-saved
	pushl	%edi
	pushl	%esi

        # eax = head; di = location integer of input
        movl    mp1_list_head, %eax
        movw    8(%ebp), %di
        cmpl    $0, %eax
        je      error_return

traverse_again:
        # traverse until found same location in the list
        movw    LOCATION(%eax), %bx
        cmpw    %bx, %di
        je      restore_reg
        # check for null and traverse to the next list
        cmpl    $0, NEXT(%eax)
        je      error_return
        movl    NEXT(%eax), %eax
        jmp     traverse_again 

error_return:
        movl    $-1, %eax       # return -1 to the caller
        popl    %esi		
	popl    %edi
	popl    %ebx

        leave
	ret

null_handler:
        # return -1
        movl    $-1, %eax				

restore_reg:
        popl    %esi		
	popl    %edi
	popl    %ebx

        leave
	ret

.end
