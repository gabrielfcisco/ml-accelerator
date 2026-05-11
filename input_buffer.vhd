library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Buffer de entrada (vetor x da camada).
-- Porta de escrita sincrona controlada pelo host.
-- Porta de leitura assincrona consumida pelo controller durante COMPUTE,
-- alimentando as 4 MACs em paralelo (broadcast do mesmo x[k]).
entity input_buffer is
    generic (
        DEPTH  : integer := 256;
        ADDR_W : integer := 8
    );
    Port (
        clk     : in  std_logic;
        we      : in  std_logic;
        wr_addr : in  std_logic_vector(ADDR_W-1 downto 0);
        wr_data : in  std_logic_vector(15 downto 0);
        rd_addr : in  std_logic_vector(ADDR_W-1 downto 0);
        rd_data : out std_logic_vector(15 downto 0)
    );
end input_buffer;

architecture rtl of input_buffer is
    type mem_t is array (0 to DEPTH-1) of std_logic_vector(15 downto 0);
    signal mem : mem_t := (others => (others => '0'));
begin

    process(clk)
    begin
        if rising_edge(clk) then
            if we = '1' then
                mem(to_integer(unsigned(wr_addr))) <= wr_data;
            end if;
        end if;
    end process;

    rd_data <= mem(to_integer(unsigned(rd_addr)));

end rtl;
