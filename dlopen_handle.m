//
//  dlopen_handle.m
//
//
//  Created by Ethan Arbuckle on 5/5/18.
//  Copyright © 2018 DataTheorem. All rights reserved.
//

#import <Foundation/Foundation.h>
#include <mach-o/loader.h>
#include <mach-o/dyld_images.h>
#include <mach-o/nlist.h>
#include <dlfcn.h>

static int iter_cmds_for_type(struct mach_header_64 *mh, uint32_t target, int only_once, void (^found)(struct load_command *lc))
{
    struct load_command *lcommand = (struct load_command *)((mach_vm_address_t)mh + sizeof(struct mach_header_64));
    for (int command = 0; command < mh->ncmds; command++)
    {
        if (lcommand->cmd == target)
        {
            found(lcommand);
            if (only_once)
            {
                return 0;
            }
        }
        
        lcommand = (struct load_command *)((mach_vm_address_t)lcommand + lcommand->cmdsize);
    }
    
    return 0;
}

static void *addr_of_symbol(struct mach_header_64 *mh, char *symbol)
{
    __block uint64_t slide = 0;
    __block struct symtab_command *symcmd = NULL;
    __block struct nlist_64 *symtab = NULL;
    __block const char *strtab = NULL;
    
    iter_cmds_for_type(mh, LC_SYMTAB, 1, ^(struct load_command *lc) {
        symcmd = (struct symtab_command *)lc;
    });
    
    iter_cmds_for_type(mh, LC_SEGMENT_64, 0, ^(struct load_command *lc) {
        struct segment_command_64 *seg = (struct segment_command_64 *)lc;
        if (seg->fileoff == 0)
        {
            slide = (intptr_t)mh - seg->vmaddr;
        }
        
        if (strcmp(seg->segname, SEG_LINKEDIT) == 0)
        {
            symtab = (void *)seg->vmaddr + symcmd->symoff - seg->fileoff;
            strtab = (void *)seg->vmaddr + symcmd->stroff - seg->fileoff;
        }
    });
    
    
    symtab = (void *)symtab + slide;
    strtab = (void *)strtab + slide;
    
    for (uint32_t i = 0; i < symcmd->nsyms; i++)
    {
        struct nlist_64 *sym = &symtab[i];
        uint32_t strx = sym->n_un.n_strx;
        const char *name = strx == 0 ? "" : strtab + strx;
        if (strcmp(name, symbol) == 0)
        {
            return (void *)sym->n_value + slide;
        }
    }
    
    return NULL;
}

static struct mach_header_64 *dyld_header()
{
    static struct mach_header_64 *mh;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        struct task_dyld_info dyld_info;
        mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
        task_info(mach_task_self_, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count);
        struct dyld_all_image_infos *infos = (struct dyld_all_image_infos *)dyld_info.all_image_info_addr;
        mh = (struct mach_header_64 *)infos->dyldImageLoadAddress;
    });
    
    return mh;
}

struct mach_header_64 *get_mach_header(void *handle)
{
    return ((struct mach_header_64 * (*)(void *))addr_of_symbol(dyld_header(), "__ZNK16ImageLoaderMachO10machHeaderEv"))(handle);
}

char *get_real_path(void *handle)
{
    return ((char * (*) (void *))addr_of_symbol(dyld_header(), "__ZNK11ImageLoader11getRealPathEv"))(handle);
}

int in_shared_cache(void *handle)
{
    return ((int (*) (void *))addr_of_symbol(dyld_header(), "__ZNK20ImageLoaderMegaDylib13inSharedCacheEv"))(handle);
}

void *private_dlsym(void *handle, char *symbol)
{
    if (handle == NULL || symbol == NULL)
    {
        return NULL;
    }

    return addr_of_symbol(get_mach_header(handle), symbol);
}
